*---------------------------------------------------------------
* extestb3.s -- continuation of extestb.s/extestb2.s/extestb4.s.
* Carries the small call helpers, call-site scratch, the
* table-driven RUN_SESSION driver (see its own header) and the
* staged file paths sessions 1-5 open -- see extestb2.s's/
* extestb4.s's own headers for why this is split four ways (the
* `as` self-host source window, docs/S9-PLAN.md sec 5). `put`
* LAST in extest.s's manifest -- everything here is reached
* only via `jsr`, never by fallthrough, so it may sit after
* extestb4.s's own infinite park loop without changing
* PARENT_PROC's behavior.
*
* 2026-09-08: this file used to carry every session 1-5
* fixture/script as embedded `asc`/`dfb $8D` text, written to
* disk at runtime -- retired, staged onto ex.po at build time
* instead (build_ex_image.py's FIXTURES; git log de7ea88).
*
* 2026-09-12: a SECOND retirement, one level up, same shape.
* de7ea88/048e792 staged embedded FIXTURE TEXT out of the image;
* this stages the per-session DRIVER CODE out of it too. Every
* session's create-capture/open-script/dup-stdio/spawn/wait/
* close/read-back-N-files sequence was ~60-80 near-identical
* instructions, copied 18 times (sessions 1-16, plus 5N/11A/11B)
* across extestb.s..extestb9.s -- the VT102 console growth
* (docs/CONSOLE-VT102.md) pushed MAUXEXTEST.SYSTEM 727B past
* PMLI_IBF_BASE, and that repetition was the fat. RUN_SESSION
* (below) is the ONE routine now; every session is a 17-byte
* descriptor {capture path, script path, argv ptr (0=NULL),
* spawn-pid/spawn-stat/wait-pid result addresses, close-early
* flag, step number, readback count, readback-list ptr} plus a
* short readback-entry table (path, buffer, maxlen, result-
* length address -- one entry per file the session reads back
* afterwards). Every result ADDRESS scripts/check_ex.py reads is
* UNCHANGED; only the code that used to fill them is gone.
* READ_FDD/DESC_RET (the inline-descriptor READ_FD wrapper
* sessions 10-16 used to save bytes at their OWN call sites) are
* retired too -- RUN_SESSION's own readback-table walk replaces
* every call site that used them.
*---------------------------------------------------------------
* Small call helpers (all raw $FF00 gates -- kernel-side test
* harness, edtestb.s's own precedent).
*---------------------------------------------------------------
OPEN_BY_PATH
            sta   OPEN_PARM+1
            stx   OPEN_PARM+2
            stz   OPEN_PARM+3
            stz   OPEN_PARM+4
            lda   #3
            sta   OPEN_PARM
            lda   #<OPEN_PARM
            ldx   #>OPEN_PARM
            ldy   #SYS_OPEN
            jsr   $FF00
            bcc   :topfail1
            jmp   PFAIL
:topfail1
            lda   OPEN_PARM+5
            rts

CRT_BY_PATH
            sta   CREATE_PARM+1
            stx   CREATE_PARM+2
            lda   #7
            sta   CREATE_PARM
            lda   #$C3
            sta   CREATE_PARM+3
            lda   #$04
            sta   CREATE_PARM+4
            stz   CREATE_PARM+5
            stz   CREATE_PARM+6
            lda   #1
            sta   CREATE_PARM+7
            stz   CREATE_PARM+8
            stz   CREATE_PARM+9
            stz   CREATE_PARM+10
            stz   CREATE_PARM+11
            lda   #<CREATE_PARM
            ldx   #>CREATE_PARM
            ldy   #SYS_CREAT
            jsr   $FF00           ;best-effort -- ignore result,
                                  ;see header
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
* STAGE_CROPEN9 -- IN: A/X = path ptr. Creates the file (best-
* effort) and opens it -- the shape every session's OWN capture
* file (EXCAPn) uses (the spawned child writes it, not
* PARENT_PROC). OUT: A = the open fd. CLOBBERS: A, X, STGPATH.
* (FF1-FF5's 2026-09-06 consolidation; its sibling STAGE_WR9,
* the "create, open, write, close" shape, went with the
* embedded fixture text on 2026-09-08 -- see the header.)
*---------------------------------------------------------------
STAGE_CROPEN9
            sta   STGPATH
            stx   STGPATH+1
            lda   STGPATH
            ldx   STGPATH+1
            jsr   CRT_BY_PATH
            lda   STGPATH
            ldx   STGPATH+1
            jsr   OPEN_BY_PATH
            rts

*-- FDA_STDIO -- the fdactions block every session's spawn uses:
*-- {DUP fd0 <- SINFD, DUP fd1 <- SOUTFD, END} into FDA1. Was
*-- 35 bytes inline in eight sessions of extestb9.s (2026-09-07,
*-- to keep MAUXEXTEST under PMLI_IBF_BASE after the lending
*-- IB1-IB5 fixes grew the kernel), and now the ONLY fdactions
*-- builder RUN_SESSION uses -- every session's spawn wants this
*-- exact shape. CLOBBERS: A.
FDA_STDIO   lda   #FDACT_DUP
            sta   FDA1
            sta   FDA1+3
            lda   #FD_STDIN
            sta   FDA1+1
            lda   SINFD
            sta   FDA1+2
            lda   #FD_STDOUT
            sta   FDA1+4
            lda   SOUTFD
            sta   FDA1+5
            stz   FDA1+6
            rts

*---------------------------------------------------------------
* RUN_SESSION -- table-driven driver for ONE ex harness session:
* create+open the capture file, open the script, dup them onto
* stdin/stdout, spawn `ex` (NULL argv or a real argv array),
* close SINFD/SOUTFD either before or after WAIT_ONE (per the
* descriptor -- sessions 1-9's own order vs. 10-16's, which
* frees io_buffer slots for the spawned child chain EARLY, see
* extestb9.s session 10's own header), then read back every file
* the descriptor lists.
*
* IN: A/X = descriptor address (lo/hi). Descriptor, 17 bytes:
*   +0  CAP_PATH      (2)  capture file -- CRT+OPEN, dup to fd1
*   +2  SCRIPT_PATH   (2)  script file -- OPEN only, dup to fd0
*   +4  ARGV_PTR      (2)  0 = SPAWN_EX (NULL argv); else the
*                          address of a {argv[0],argv[1],NULL}
*                          array -- SPAWN_EX_A
*   +6  SPAWN_PID_ADDR(2)  [addr] = spawn()'s own return value
*   +8  SPAWN_STAT_ADDR(2) WAIT_ONE's WSTATUSPTR target
*   +10 WAIT_PID_ADDR (2)  [addr] = WAIT_ONE's return value
*   +12 CLOSE_EARLY   (1)  0 = close after WAIT_ONE, else before
*   +13 SESS_NO       (1)  R_STEP value while this session runs
*                          (diagnostic only -- check_ex.py never
*                          asserts an exact R_STEP)
*   +14 RB_COUNT      (1)  number of readback-list entries
*   +15 RB_LIST       (2)  address of RB_COUNT 8-byte entries:
*                          {path(2), buf(2), maxlen(2), result-
*                          length address(2)} -- OPEN/READ_FD/
*                          CLOSE in list order, each entry's own
*                          byte count landing at its own result
*                          address (session 8's own capture-
*                          file order is just list order; no
*                          special-casing needed).
*
* CLOBBERS: A,X,Y and every SOUTFD/SINFD/FDA1/AVPTR/RFD/RBUFPTR/
* RMAXLEN/WSTATUSPTR/SFDAPTR cell the old inline code already
* shared across sessions, plus DESC_BUF/RB_ENT/RB_IDX/INDPTR
* (this routine's own scratch).
*---------------------------------------------------------------
RUN_SESSION sta   :dsrc+1
            stx   :dsrc+2
            ldy   #0
:dcpy
:dsrc       lda   $FFFF,y
            sta   DESC_BUF,y
            iny
            cpy   #17
            bne   :dcpy

            lda   DESC_BUF+13        ;SESS_NO -- diagnostic only
            sta   R_STEP

            lda   DESC_BUF+0
            ldx   DESC_BUF+1
            jsr   STAGE_CROPEN9
            sta   SOUTFD

            lda   DESC_BUF+2
            ldx   DESC_BUF+3
            jsr   OPEN_BY_PATH
            sta   SINFD

            jsr   FDA_STDIO
            lda   #<FDA1
            sta   SFDAPTR
            lda   #>FDA1
            sta   SFDAPTR+1

*-- spawn: INDPTR set BEFORE the argv check so the pid (returned
*-- in A by SPAWN_EX/SPAWN_EX_A) survives untouched into STINDA.
            lda   DESC_BUF+6
            sta   INDPTR
            lda   DESC_BUF+7
            sta   INDPTR+1
            lda   DESC_BUF+4
            ora   DESC_BUF+5
            beq   :rsnoav
            lda   DESC_BUF+4
            sta   AVPTR
            lda   DESC_BUF+5
            sta   AVPTR+1
            jsr   SPAWN_EX_A
            bra   :rsspwd
:rsnoav     jsr   SPAWN_EX
:rsspwd     jsr   STINDA              ;[SPAWN_PID_ADDR] = pid

            lda   DESC_BUF+12
            beq   :rslate
            jsr   RS_CLOSE
:rslate     lda   DESC_BUF+10
            sta   INDPTR
            lda   DESC_BUF+11
            sta   INDPTR+1
            lda   DESC_BUF+8
            sta   WSTATUSPTR
            lda   DESC_BUF+9
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            jsr   STINDA              ;[WAIT_PID_ADDR] = pid

            lda   DESC_BUF+12
            bne   :rsrb
            jsr   RS_CLOSE

:rsrb       stz   RB_IDX
:rsrblp     lda   RB_IDX
            cmp   DESC_BUF+14
            beq   :rsrbdn
            jsr   RS_READBK
            inc   RB_IDX
            bra   :rsrblp
:rsrbdn     rts

*-- RS_CLOSE -- close SINFD then SOUTFD, the pair every session
*-- closes together, early or late per CLOSE_EARLY.
RS_CLOSE    lda   SINFD
            jsr   CLOSE_FD
            lda   SOUTFD
            jsr   CLOSE_FD
            rts

*-- RS_READBK -- open+read+close ONE readback-list entry (index
*-- RB_IDX of DESC_BUF's own RB_LIST) into RB_ENT, then the
*-- entry's own buffer/result-length cell.
RS_READBK   lda   RB_IDX
            asl   a
            asl   a
            asl   a                  ;RB_IDX*8
            clc
            adc   DESC_BUF+15
            sta   :rbsrc+1
            lda   DESC_BUF+16
            adc   #0
            sta   :rbsrc+2
            ldy   #0
:rbcpy
:rbsrc      lda   $FFFF,y
            sta   RB_ENT,y
            iny
            cpy   #8
            bne   :rbcpy

            lda   RB_ENT+0
            ldx   RB_ENT+1
            jsr   OPEN_BY_PATH
            sta   RFD
            lda   RB_ENT+2
            sta   RBUFPTR
            lda   RB_ENT+3
            sta   RBUFPTR+1
            lda   RB_ENT+4
            sta   RMAXLEN
            lda   RB_ENT+5
            sta   RMAXLEN+1
            lda   RB_ENT+6
            sta   INDPTR
            lda   RB_ENT+7
            sta   INDPTR+1
            jsr   READ_FD
            jsr   STINDA             ;[result addr]=byte count
            lda   RFD
            jsr   CLOSE_FD
            rts

*-- STINDA -- store A at the address held in INDPTR/INDPTR+1.
*-- Self-modifying `sta $FFFF` (patched from INDPTR); no zero
*-- page needed -- the SAME technique this file's own (retired)
*-- READ_FDD/DESC_RET used. IN: A=value, INDPTR=target address.
*-- CLOBBERS: A.
STINDA      sta   :val+1
            lda   INDPTR
            sta   :tgt+1
            lda   INDPTR+1
            sta   :tgt+2
:val        lda   #0
:tgt        sta   $FFFF
            rts

READ_FD     lda   RFD
            sta   READ_PARM+1
            lda   RBUFPTR
            sta   READ_PARM+2
            lda   RBUFPTR+1
            sta   READ_PARM+3
            lda   RMAXLEN
            sta   READ_PARM+4
            lda   RMAXLEN+1
            sta   READ_PARM+5
            lda   #4
            sta   READ_PARM
            lda   #<READ_PARM
            ldx   #>READ_PARM
            ldy   #SYS_READ
            jsr   $FF00
            bcc   :topfail3
            jmp   PFAIL
:topfail3
            lda   READ_PARM+6
            rts

SPAWN_EX    lda   #<PATH_EX
            sta   SPAWN_PARM
            lda   #>PATH_EX
            sta   SPAWN_PARM+1
            stz   SPAWN_PARM+2
            stz   SPAWN_PARM+3
            lda   SFDAPTR
            sta   SPAWN_PARM+4
            lda   SFDAPTR+1
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :topfail4
            jmp   PFAIL
:topfail4
            rts

*---------------------------------------------------------------
* SPAWN_EX_A -- SPAWN_EX's own shape, but with a REAL argv (IN:
* AVPTR = the caller's ARGV_ARR pointer) instead of NULL --
* session 5's filename-on-launch cases (edtestb.s's SPAWN_ED_A
* is the same idea for `ed`).
*---------------------------------------------------------------
SPAWN_EX_A  lda   #<PATH_EX
            sta   SPAWN_PARM
            lda   #>PATH_EX
            sta   SPAWN_PARM+1
            lda   AVPTR
            sta   SPAWN_PARM+2
            lda   AVPTR+1
            sta   SPAWN_PARM+3
            lda   SFDAPTR
            sta   SPAWN_PARM+4
            lda   SFDAPTR+1
            sta   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcc   :topfail6
            jmp   PFAIL
:topfail6
            rts

WAIT_ONE    lda   WSTATUSPTR
            sta   WAIT_PARM
            lda   WSTATUSPTR+1
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            bcc   :topfail5
            jmp   PFAIL
:topfail5
            rts

*---------------------------------------------------------------
* Call-site scratch (all bank-1 addresses, part of the copied
* span).
*---------------------------------------------------------------
SOUTFD      ds    1
SINFD       ds    1
SCAPRFD     ds    1
SOUTRFD     ds    1
STGPATH     ds    2   ;STAGE_CROPEN9's path scratch
RFD         ds    1
RBUFPTR     ds    2
RMAXLEN     ds    2
SFDAPTR     ds    2
WSTATUSPTR  ds    2
FDA1        ds    7

*-- RUN_SESSION's own scratch: the copied-in descriptor, the
*-- current readback-list entry, its loop index, and STINDA's
*-- indirect-store target.
DESC_BUF    ds    17
RB_ENT      ds    8
RB_IDX      ds    1
INDPTR      ds    2
*-- RS_DONTCARE -- shared sink for a descriptor field a session
*-- has no result cell for (5N never stored spawn/wait pid
*-- either, in the old per-session code).
RS_DONTCARE ds    2

OPEN_PARM      dfb   0
OPEN_PRM_PATH da    0
OPN_PRM_IOBUF da   0
OPEN_PARM_REF  dfb   0
CREATE_PARM    ds    12
CLOSE_PARM     ds    2
READ_PARM      ds    8
SPAWN_PARM     ds    8   ;path,argv,fdactions,envp
WAIT_PARM      ds    2

* -- fifth session (filename-on-launch) -- AVPTR is SPAWN_EX_A's
* -- own argv pointer, set by RUN_SESSION from the descriptor's
* -- own ARGV_PTR field before every argv-bearing spawn.
AVPTR          ds    2

*---------------------------------------------------------------
* Paths -- MLI shape (1-byte count, then raw 7-bit chars, `asc
* '...'` single-quoted, NOT NUL-terminated). Only the files the
* harness itself opens: each session's script (stdin), capture
* (stdout) and whatever it reads back afterwards. The fixtures
* a script names in its own `r`/`e`/`w` lines (EXSRC, EXSRC2,
* ...) need no path here since 2026-09-08 -- build_ex_image.py
* stages them.
*---------------------------------------------------------------
PATH_EXSCR1  dfb 16
             asc '/mnt/MAUX/EXSCR1'
PATH_EXCAP   dfb 15
             asc '/mnt/MAUX/EXCAP'
PATH_EXOUT   dfb 15
             asc '/mnt/MAUX/EXOUT'

* -- second session (Task 0's `j` fix) paths --
PATH_EXSCR2  dfb 16
             asc '/mnt/MAUX/EXSCR2'
PATH_EXCAP2  dfb 16
             asc '/mnt/MAUX/EXCAP2'
PATH_EXOUT2  dfb 16
             asc '/mnt/MAUX/EXOUT2'

* -- third session (marks/undo/#-print) paths --
PATH_EXSCR3  dfb 16
             asc '/mnt/MAUX/EXSCR3'
PATH_EXCAP3  dfb 16
             asc '/mnt/MAUX/EXCAP3'
PATH_EXOUT3  dfb 16
             asc '/mnt/MAUX/EXOUT3'

* -- fourth session (?re?/e/e!/wq) paths -- EXSRC4B is re-read
* -- after the script's own `wq`.
PATH_EXSRC4B dfb 17
             asc '/mnt/MAUX/EXSRC4B'
PATH_EXSCR4  dfb 16
             asc '/mnt/MAUX/EXSCR4'
PATH_EXCAP4  dfb 16
             asc '/mnt/MAUX/EXCAP4'

* -- fifth session (2026-09-02, filename-on-launch) paths --
PATH_EXFILE5 dfb 17
             asc '/mnt/MAUX/EXFILE5'
PATH_EXSCR5  dfb 16
             asc '/mnt/MAUX/EXSCR5'
PATH_EXCAP5  dfb 16
             asc '/mnt/MAUX/EXCAP5'
PATH_EXSCR5N dfb 17
             asc '/mnt/MAUX/EXSCR5N'
PATH_EXCAP5N dfb 17
             asc '/mnt/MAUX/EXCAP5N'

* SPAWN's path argument -- a liba string (high-bit, NUL-
* terminated), per the ratified spawn() ABI -- NOT an MLI
* pathname.
PATH_EX      asc   "/bin/EX"
             dfb   0

* -- session 5's argv[0]/argv[1] strings -- SAME liba-string
* -- shape as PATH_EX above (high-bit, NUL-terminated); these
* -- are what the kernel repacks into the child's ARGC/ARGV,
* -- per startup.equ and docs/SYSCALL.md item 13. AV_EXFILE5
* -- names the SAME file staged at PATH_EXFILE5; AV_EXNOSUCH
* -- deliberately names a path nothing creates.
AV_EX0       asc   "EX"
             dfb   0
AV_EXFILE5   asc   "/mnt/MAUX/EXFILE5"
             dfb   0
AV_EXNOSUCH  asc   "/mnt/MAUX/EXNOSUCH5"
             dfb   0

* -- ARGV_ARR5/ARGV_ARR5N -- 2026-09-12: static now (was `ds 6`,
* -- filled at runtime by 6 stores apiece before every spawn).
* -- Every value here is a compile-time-constant address, so the
* -- old runtime fill bought nothing but code size -- same
* -- insight as staging the fixture text itself (this file's own
* -- header).
ARGV_ARR5    da    AV_EX0,AV_EXFILE5,0
ARGV_ARR5N   da    AV_EX0,AV_EXNOSUCH,0

*---------------------------------------------------------------
* Sessions 1-5's fixture/script content -- the BYTES are
* build_ex_image.py's FIXTURES (staged at build time since
* 2026-09-08, see the header); what each one is FOR stays here,
* where the text used to sit, immediately followed by that
* session's own RUN_SESSION descriptor + readback list.
*
* EXSRC -- the file session 1 loads via `r`. Five lines, one
* occurrence of "BANK" on line 2 (the substitution target) and a
* SECOND, untouched "BANK" on line 4 -- proves `2s/BANK/SWAPD/`
* only rewrites the addressed line, not every occurrence in the
* buffer.
*
* EXSCR1 -- session 1's script, fed to `ex` on fd 0. r (load)
* -> ,p (print all, swap-backed) -> s (rewrite line 2, through
* ED_BUMP_ALLOC/ED_SETSLOT) -> ,p again (line 2 changed, 1/3/4/5
* re-read from their ORIGINAL now out-of-sequence swap offsets)
* -> w (write back, fetching every line through the swap again)
* -> q (quit, unlinks the swap file).
*---------------------------------------------------------------
DESC1       da    PATH_EXCAP,PATH_EXSCR1,0
            da    R_SPAWN_PID,R_SPAWN_STAT,R_WAIT_PID
            dfb   0,1,2
            da    RBL1
RBL1        da    PATH_EXCAP,R_STAGE1
            dfb   200,0
            da    R_LEN1
            da    PATH_EXOUT,R_STAGEOUT
            dfb   200,0
            da    R_LENOUT

*---------------------------------------------------------------
* EXSRC2 -- the file the SECOND session loads via `r`. Five
* short lines L1..L5 (edtestb.s's own Session-5 `j` fixture
* shape), well under the 254-byte join cap so the fix's own
* teeth (not the length-cap refusal) are what this exercises.
*
* EXSCR2 -- r (load) -> 1,2j (2-line join: L1+L2 -> "L1L2",
* table now L1L2/L3/L4/L5) -> ,p (print all 4, swap-backed) ->
* 2,4j (3-line join over the NOW-4-line buffer: L3+L4+L5 ->
* "L3L4L5", table now L1L2/L3L4L5) -> ,p again (re-reads the
* FIRST join's line -- L1L2 -- a SECOND time, from its real swap
* descriptor, plus the new second join) -> w /mnt/MAUX/EXOUT2
* (re-
* reads BOTH joined lines a THIRD time via an independent
* SET_MARK+READ) -> q.
*---------------------------------------------------------------
DESC2       da    PATH_EXCAP2,PATH_EXSCR2,0
            da    R_SPAWN_PID2,R_SPAWN_STAT2,R_WAIT_PID2
            dfb   0,2,2
            da    RBL2
RBL2        da    PATH_EXCAP2,R_STAGE2
            dfb   200,0
            da    R_LEN2
            da    PATH_EXOUT2,R_STAGEOUT2
            dfb   200,0
            da    R_LENOUT2

*---------------------------------------------------------------
* EXSRC3 -- the file the THIRD session loads: M1..M5.
*
* EXSCR3 -- marks (set/ref/shift-on-insert/shift-on-delete/
* invalidate-on-delete), undo round-trip, #-print, n reserved,
* and a final `x` (dirty -- writes back through the remembered
* filename, EXSRC3 itself, then quits). See check_ex.py's own
* header comment for the full derivation of the expected bytes
* this drives.
*---------------------------------------------------------------
DESC3       da    PATH_EXCAP3,PATH_EXSCR3,0
            da    R_SPAWN_PID3,R_SPAWN_STAT3,R_WAIT_PID3
            dfb   0,3,2
            da    RBL3
RBL3        da    PATH_EXCAP3,R_STAGE3
            dfb   200,0
            da    R_LEN3
            da    PATH_EXOUT3,R_STAGEOUT3
            dfb   200,0
            da    R_LENOUT3

*---------------------------------------------------------------
* EXSRC4/EXSRC4B -- the two files the FOURTH session uses.
* EXSRC4 (B1,B2,B3) is loaded first (backward search + insert);
* EXSRC4B (C1,C2) is loaded by `e!` (replacing the whole buffer)
* and is also `wq`'s write target at the end (its own remembered
* name after the e!).
*
* EXSCR4 -- r (load B1,B2,B3) -> ?B2?p (backward search, wraps
* from .=3 down to 2, matches -- prints "B2") -> ?ZZZ?p
* (backward search, no match anywhere -- wraps through every
* line, fails -> falls through to the bare `?` as an unrecog-
* nized command -> "?") -> 1a/NEWB/. (insert, EX_DIRTY=1) -> ,p
* (prints the 4-line buffer) -> e /mnt/MAUX/EXSRC4B (refused --
* `?`
* -- buffer is dirty and no `!`) -> e! /mnt/MAUX/EXSRC4B (force
* --
* discards the dirty buffer, loads EXSRC4B fresh, EX_DIRTY
* cleared) -> ,p (prints C1,C2 -- proves the reload) -> wq
* (writes C1,C2 back to EXSRC4B -- the name `e!` remembered --
* then quits, regardless of EX_DIRTY==0 at this point: "wq = w
* then q" unconditionally, unlike `x`).
*
* RS_DONTCARE for pid/wait -- the old per-session code stored
* session 4's spawn/wait pid into session 3's OWN cells (an
* unused-but-harmless reuse quirk); check_ex.py checks neither,
* so the descriptor form just says "don't care" outright.
*---------------------------------------------------------------
DESC4       da    PATH_EXCAP4,PATH_EXSCR4,0
            da    RS_DONTCARE,R_SPAWN_STAT4,RS_DONTCARE
            dfb   0,4,2
            da    RBL4
RBL4        da    PATH_EXCAP4,R_STAGE4
            dfb   200,0
            da    R_LEN4
            da    PATH_EXSRC4B,R_STAGEOUT4
            dfb   200,0
            da    R_LENOUT4

*---------------------------------------------------------------
* EXFILE5 (session 5, filename-on-launch) -- the file `ex` loads
* at STARTUP via argv[1], not `r` -- through the swap file, same
* as every real `r` this gate has already exercised: un/deux/
* trois.
*
* EXSCR5 -- the script fed to the launch-loaded `ex` on fd 0. NO
* `r` anywhere -- `,p` alone proves the swap-backed buffer was
* already populated at startup, and the bare `w` (no filename
* token) proves the remembered filename was set to EXFILE5 by
* the launch load, not left empty.
*---------------------------------------------------------------
DESC5       da    PATH_EXCAP5,PATH_EXSCR5,ARGV_ARR5
            da    R_SPAWN_PID5,R_SPAWN_STAT5,R_WAIT_PID5
            dfb   0,5,2
            da    RBL5
RBL5        da    PATH_EXCAP5,R_STAGE5
            dfb   48,0
            da    R_LEN5
            da    PATH_EXFILE5,R_STAGEOUT5
            dfb   32,0
            da    R_LENOUT5

*---------------------------------------------------------------
* EXSCR5N -- the negative case's script: bare `w` with nothing
* remembered (the open at startup failed) must stay `?`, same
* posture as `ed`'s own EDSCR6N_TEXT (edtestb.s). Only ONE
* readback (the capture) -- the launch load failed, so there is
* no second file to reopen.
*---------------------------------------------------------------
DESC5N      da    PATH_EXCAP5N,PATH_EXSCR5N,ARGV_ARR5N
            da    RS_DONTCARE,R_SPWN_STAT5N,RS_DONTCARE
            dfb   0,6,1
            da    RBL5N
RBL5N       da    PATH_EXCAP5N,R_STAGE5N
            dfb   16,0
            da    R_LEN5N

PAR_PROC_LEN equ *-PARENT_PROC
