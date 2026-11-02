*---------------------------------------------------------------
* edtestb2.s -- continuation of edtestb.s's PARENT_PROC ("last
* regular expression" task, 2026-09-02). Split purely for real
* Merlin's 41,215-byte source-buffer budget (check-dialect's
* hazard 3, scripts/check_dialect.py) -- edtestb.s alone grew
* past it once Session 7 landed there. Same split shape as
* extest.s's own extestb2.s->extestb4.s: this file carries
* PARENT_PROC's SEVENTH session driver plus its own epilogue
* (:donepark/PFAIL/:pfailpark), all of Session 7's scratch/
* paths/content, and the final PAR_PROC_LEN equate --
* edtestb.s's own tail falls straight through into this driver
* (no jmp needed; `put` is textual inclusion, one continuous
* instruction stream). `put` in edtest.s right after edtestb.s.
*---------------------------------------------------------------
* -- Session 7 result addresses, same "$1200-$1FFF is free
* -- scratch" block edtestb.s's own sessions use. --
R_LEN7      equ   $1700      ;byte count from EDOUT7
R_STAGE7    equ   $1710      ;up to 112 bytes -- ends $177F
R_LEN7B     equ   $1780      ;byte count from EDFILE7, RE-READ
                             ;after the script's own `w`
R_STAGE7B   equ   $1790      ;up to 80 bytes -- ends $17DF
R_SPAWN7_PID  equ $17E0
R_SPAWN7_STAT equ $17E1
R_WAIT7_PID   equ $17E2

* -- Session 8 result addresses, own block $1800-$19FF. Grown
* -- for FF1 (2026-09-06, review): the g/v engine's own
* -- session picks up one more phase (below), so the capture/
* -- EDFILE8 windows and the spawn-result cells all moved out
* -- to make room -- still well inside $1800-$19FF, clear of
* -- session 9's own $1A00 floor. --
R_LEN8      equ   $1800      ;byte count from EDOUT8
R_STAGE8    equ   $1810      ;up to 232 bytes -- ends $18F7
R_LEN8B     equ   $1900      ;byte count from EDFILE8, RE-READ
                             ;after the script's own `w`
R_STAGE8B   equ   $1908      ;up to 64 bytes -- ends $1947
R_SPAWN8_PID  equ $1970
R_SPAWN8_STAT equ $1971
R_WAIT8_PID   equ $1972

* -- Session 9 result addresses, own block $1A00-$1AFF. Proves
* `w` TRUNCATES: a long buffer is written to EDFILE9, then a
* short buffer overwrites it via a bare `w` -- if SET_EOF is
* missing, ProDOS's OPEN leaves the old EOF in place and the
* short write leaves a stale tail past the new content. --
R_LEN9      equ   $1A00      ;byte count from EDFILE9 (post-w)
R_STAGE9    equ   $1A10      ;up to 96 bytes -- ends $1A6F
R_LEN9O     equ   $1A70      ;byte count from EDOUT9 (must stay
                             ;empty -- no `p` in EDSCR9)
R_STAGE9O   equ   $1A78      ;scratch target, 0 bytes expected
R_SPAWN9_PID  equ $1A80
R_SPAWN9_STAT equ $1A81
R_WAIT9_PID   equ $1A82

* -- Session 10 (XC1, 2026-09-06, second closing pass)
* -- result addresses, own block $1B00-$1BFF. Restores the
* -- unnamed-buffer first-save/second-save coverage EX4's own
* -- test rework (session 9's TWO explicit `w /mnt/MAUX/EDFILE9`
* -- lines, above) dropped -- see the header above SESS10START.
R_LEN10O    equ   $1B00      ;byte count from EDCAP10 (0
                             ;expected, no `p` in EDSCR10)
R_STAGE10O  equ   $1B08      ;scratch target, 0 bytes expected
R_LEN10     equ   $1B20      ;byte count from ED10FRESH (post-w)
R_STAGE10   equ   $1B28      ;up to 16 bytes -- ends $1B37
R_SPAWN10_PID  equ $1B40
R_SPAWN10_STA equ $1B41
R_WAIT10_PID   equ $1B42

*---------------------------------------------------------------
* SEVENTH session -- "last regular expression" task
* (2026-09-02, learning:01M1FX8HT89CKR9CB8T8VKCW1S): a bare `//`
* with no prior search is `?` (no crash, no empty-matches-
* everything); `/BANK/p` then a bare `//` re-finds the NEXT
* `BANK` (forward repeat);
* `s/OLD/NEW/` then a later `s//X/` reuses OLD as the search
* field. One script, one stdout capture, one written-file read-
* back -- same shape as edtestb.s's own Session 5. See
* EDSCR7's trace, below PATH_EDFILE7 (build_ed_image.py stages
* the bytes).
*---------------------------------------------------------------
            lda   #22
            sta   R_STEP
* ---- EDSCR7 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDOUT7
            ldx   #>PATH_EDOUT7
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT7
            ldx   #>PATH_EDOUT7
            jsr   OPEN_BY_PATH
            sta   S7OUTFD

            lda   #<PATH_EDSCR7
            ldx   #>PATH_EDSCR7
            jsr   OPEN_BY_PATH
            sta   S7INFD

            lda   #23
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA7
            lda   #FD_STDIN
            sta   FDA7+1
            lda   S7INFD
            sta   FDA7+2
            lda   #FDACT_DUP
            sta   FDA7+3
            lda   #FD_STDOUT
            sta   FDA7+4
            lda   S7OUTFD
            sta   FDA7+5
            stz   FDA7+6

            lda   #<FDA7
            sta   SFDAPTR
            lda   #>FDA7
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN7_PID

            lda   #<R_SPAWN7_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN7_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT7_PID

            lda   #24
            sta   R_STEP
            lda   S7INFD
            jsr   CLOSE_FD
            lda   S7OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT7
            ldx   #>PATH_EDOUT7
            jsr   OPEN_BY_PATH
            sta   S7ARFD
            lda   S7ARFD
            sta   RFD
            lda   #<R_STAGE7
            sta   RBUFPTR
            lda   #>R_STAGE7
            sta   RBUFPTR+1
            lda   #112
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN7
            lda   S7ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE7
            ldx   #>PATH_EDFILE7
            jsr   OPEN_BY_PATH
            sta   S7BRFD
            lda   S7BRFD
            sta   RFD
            lda   #<R_STAGE7B
            sta   RBUFPTR
            lda   #>R_STAGE7B
            sta   RBUFPTR+1
            lda   #80
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN7B
            lda   S7BRFD
            jsr   CLOSE_FD

*---------------------------------------------------------------
* EIGHTH session -- widened g/v task (2026-09-02,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S): `g/re/s///` (the
* general dispatch path, not the old p/d-only scope), `g/re/d`
* (renumber-safety -- deleting matched lines must not skip or
* double),
* `v/re/p` (the negated-match variant), and the refusal of a
* `g`/`u` appearing inside cmds (`?`, no crash, buffer/dot
* untouched -- checked BEFORE pass 1 ever marks anything). See
* EDSCR8's trace, below PATH_EDFIX1 (build_ed_image.py stages
* the bytes).
*---------------------------------------------------------------
            lda   #25
            sta   R_STEP
* -- FF1 (2026-09-06, review): EDFIX1 -- the classic-`r`
* -- fixture the `g/GONE/r EDFIX1` phase (EDSCR8's trace below)
* -- reads, 9 chars long enough to reach cmds' own start in
* -- CMDBUF for a "g/GONE/" (7-char) prefix, see edsub2.s's own
* -- GCMDBUF fix comment for why that threshold matters -- and
* -- EDSCR8 are both staged by build_ed_image.py (see session
* -- 1). ----

            lda   #<PATH_EDOUT8
            ldx   #>PATH_EDOUT8
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT8
            ldx   #>PATH_EDOUT8
            jsr   OPEN_BY_PATH
            sta   S8OUTFD

            lda   #<PATH_EDSCR8
            ldx   #>PATH_EDSCR8
            jsr   OPEN_BY_PATH
            sta   S8INFD

            lda   #26
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA8
            lda   #FD_STDIN
            sta   FDA8+1
            lda   S8INFD
            sta   FDA8+2
            lda   #FDACT_DUP
            sta   FDA8+3
            lda   #FD_STDOUT
            sta   FDA8+4
            lda   S8OUTFD
            sta   FDA8+5
            stz   FDA8+6

            lda   #<FDA8
            sta   SFDAPTR
            lda   #>FDA8
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN8_PID

            lda   #<R_SPAWN8_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN8_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT8_PID

            lda   #27
            sta   R_STEP
            lda   S8INFD
            jsr   CLOSE_FD
            lda   S8OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT8
            ldx   #>PATH_EDOUT8
            jsr   OPEN_BY_PATH
            sta   S8ARFD
            lda   S8ARFD
            sta   RFD
            lda   #<R_STAGE8
            sta   RBUFPTR
            lda   #>R_STAGE8
            sta   RBUFPTR+1
            lda   #232
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN8
            lda   S8ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE8
            ldx   #>PATH_EDFILE8
            jsr   OPEN_BY_PATH
            sta   S8BRFD
            lda   S8BRFD
            sta   RFD
            lda   #<R_STAGE8B
            sta   RBUFPTR
            lda   #>R_STAGE8B
            sta   RBUFPTR+1
            lda   #64
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN8B
            lda   S8BRFD
            jsr   CLOSE_FD

*---------------------------------------------------------------
* NINTH session -- `w` truncation (bug fix, 2026-09-02): a `w`
* onto an EXISTING file must not leave a stale tail when the new
* buffer is SHORTER than what the file already held. One script,
* one session: write a 6-line ("long") buffer to EDFILE9 via an
* explicit `w`, delete the whole buffer, insert a 2-line
* ("short") buffer, and `w` EDFILE9 again explicitly
* (2026-09-06, EX4: `w PATH` no longer rebinds the remembered
* name, so a bare `w` here would no longer reach EDFILE9 --
* named explicitly instead) -- the exact shape ED_DOWRITE takes
* every time. See
* EDSCR9's trace, below PATH_EDFILE9 (build_ed_image.py stages
* the bytes).
*---------------------------------------------------------------
            lda   #28
            sta   R_STEP
* ---- EDSCR9 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDOUT9
            ldx   #>PATH_EDOUT9
            jsr   CRT_BY_PATH
            lda   #<PATH_EDOUT9
            ldx   #>PATH_EDOUT9
            jsr   OPEN_BY_PATH
            sta   S9OUTFD

            lda   #<PATH_EDSCR9
            ldx   #>PATH_EDSCR9
            jsr   OPEN_BY_PATH
            sta   S9INFD

            lda   #29
            sta   R_STEP
            lda   #FDACT_DUP
            sta   FDA9
            lda   #FD_STDIN
            sta   FDA9+1
            lda   S9INFD
            sta   FDA9+2
            lda   #FDACT_DUP
            sta   FDA9+3
            lda   #FD_STDOUT
            sta   FDA9+4
            lda   S9OUTFD
            sta   FDA9+5
            stz   FDA9+6

            lda   #<FDA9
            sta   SFDAPTR
            lda   #>FDA9
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN9_PID

            lda   #<R_SPAWN9_STAT
            sta   WSTATUSPTR
            lda   #>R_SPAWN9_STAT
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT9_PID

            lda   #30
            sta   R_STEP
            lda   S9INFD
            jsr   CLOSE_FD
            lda   S9OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDOUT9
            ldx   #>PATH_EDOUT9
            jsr   OPEN_BY_PATH
            sta   S9ARFD
            lda   S9ARFD
            sta   RFD
            lda   #<R_STAGE9O
            sta   RBUFPTR
            lda   #>R_STAGE9O
            sta   RBUFPTR+1
            lda   #8
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN9O
            lda   S9ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFILE9
            ldx   #>PATH_EDFILE9
            jsr   OPEN_BY_PATH
            sta   S9BRFD
            lda   S9BRFD
            sta   RFD
            lda   #<R_STAGE9
            sta   RBUFPTR
            lda   #>R_STAGE9
            sta   RBUFPTR+1
            lda   #96
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN9
            lda   S9BRFD
            jsr   CLOSE_FD

            jmp   SESS10START

PFAIL       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:pfailpark  bra   :pfailpark

*---------------------------------------------------------------
* Small call helpers (all raw $FF00 gates -- this is a kernel-
* side test harness, not a src/bin util, so the liba choke-point
* rule doesn't apply here, same as fileproctest.s).
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
            lda   #$06
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

SPAWN_ED    lda   #<PATH_ED
            sta   SPAWN_PARM
            lda   #>PATH_ED
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
* SPAWN_ED_A -- SPAWN_ED's own shape, but with a REAL argv (IN:
* AVPTR = the caller's ARGV_ARR pointer) instead of NULL --
* session 6's filename-on-launch cases.
*---------------------------------------------------------------
SPAWN_ED_A  lda   #<PATH_ED
            sta   SPAWN_PARM
            lda   #>PATH_ED
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

*---------------------------------------------------------------
* Call-site scratch: MOVED to the dum block at the end of this
* file (KSPACE2) -- bank-1 addresses just past the copied span.
*---------------------------------------------------------------

* -- session 6 (filename-on-launch) --

OPEN_PARM      dfb   0
OPEN_PRM_PATH da    0
OPN_PRM_IOBUF da   0
OPEN_PARM_REF  dfb   0

*---------------------------------------------------------------
* Paths -- MLI shape (1-byte count, then raw 7-bit chars, `asc
* '...'` single-quoted per learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0
* -- NOT NUL- terminated, matches inc/mli.equ's transcribed
* OPEN/CREATE shape).
*---------------------------------------------------------------
PATH_EDSCR1  dfb 16
             asc '/mnt/MAUX/EDSCR1'
PATH_EDOUT1  dfb 16
             asc '/mnt/MAUX/EDOUT1'
PATH_EDFILE  dfb 16
             asc '/mnt/MAUX/EDFILE'
PATH_EDSCR2  dfb 16
             asc '/mnt/MAUX/EDSCR2'
PATH_EDOUT2  dfb 16
             asc '/mnt/MAUX/EDOUT2'
PATH_EDFILE2 dfb 17
             asc '/mnt/MAUX/EDFILE2'

* 2026-08-19 audit-fix phases -- findings 1 (s///N + bad flag),
* 2 (no-match /re/), 4 (m/t incl. self-range), 5 (bare address),
* 6 (bare `,`/`;`). See T.EDTEST.TXT and the task report for the
* full per-line trace this drives. The trailing write was
* REWORKED 2026-09-06 (EX4): `w PATH` no longer rebinds the
* remembered filename, so the second write now names
* /mnt/MAUX/EDFILE3 explicitly instead of riding a bare `w`'s
* old
* reuse of the first write's target -- same bytes land on disk.
* EDSCR3 content is build_ed_image.py's FIXTURES (see session
* 1's own note above PARENT_PROC).
PATH_EDSCR3  dfb 16
             asc '/mnt/MAUX/EDSCR3'
PATH_EDOUT3  dfb 16
             asc '/mnt/MAUX/EDOUT3'
PATH_EDFILE3 dfb 17
             asc '/mnt/MAUX/EDFILE3'

* Finding 3's NEGATIVE case -- a fresh ed process, no r/w yet,
* bare `w` must stay `?`. EDSCR4 content is build_ed_image.py's
* FIXTURES.
PATH_EDSCR4  dfb 16
             asc '/mnt/MAUX/EDSCR4'
PATH_EDOUT4  dfb 16
             asc '/mnt/MAUX/EDOUT4'

* Session 5 (task: "ed grows j and ="). Buffer starts as 5 lines
* L1..L5. Per-command trace:
*   1,2j          -> (no output) explicit 2-line join: L1+L2 ->
*                    "L1L2", .=1, $=4
*   p             -> "L1L2"
*   =             -> "4"       (no address -- default $)
*   2,4j          -> (no output) explicit 3-line join: L3+L4+L5
*                    -> "L3L4L5", .=2, $=2
*   p             -> "L3L4L5"
*   1=            -> "1"       (explicit address; . stays 2 --
*                    `=` never touches . or the buffer)
*   p             -> "L3L4L5"  (proves `=` above left . at 2)
*   1p            -> "L1L2"    (an ordinary address move, .=1)
*   j             -> (no output) DEFAULT range `.,.+1` = 1,2 --
*                    joins "L1L2"+"L3L4L5" -> "L1L2L3L4L5",
*                    .=1, $=1
*   p             -> "L1L2L3L4L5"
*   1j            -> (no output) single address, addr1==addr2
*                    after ED_JDFLT_RNG's 1-address rule -- the
*                    file header's NO-OP case
*   p             -> "L1L2L3L4L5" (unchanged -- proves the no-op
*                    really did nothing)
*   w /mnt/MAUX/EDFILE5, q
* EDSCR5 content is build_ed_image.py's FIXTURES.
PATH_EDSCR5  dfb 16
             asc '/mnt/MAUX/EDSCR5'
PATH_EDOUT5  dfb 16
             asc '/mnt/MAUX/EDOUT5'
PATH_EDFILE5 dfb 17
             asc '/mnt/MAUX/EDFILE5'

* -- session 6 (filename-on-launch) paths. EDFILE6 -- the file
* -- `ed` loads at STARTUP via argv[1], not `r` -- ed's own file
* -- convention (high-bit ASCII, $8D line separator). EDSCR6 --
* -- the command script fed to the launch-loaded `ed` on fd 0.
* -- NO `r` anywhere -- `,p` alone proves the buffer was already
* -- populated at startup, and the bare `w` (no filename token)
* -- proves ED_CURFNAME was set to EDFILE6 by the launch load,
* -- not left empty. EDSCR6N -- the negative case's script: bare
* -- `w` with nothing remembered (the open at startup failed)
* -- must stay `?`, exactly finding 3's cold case (session 4) --
* -- proving a failed launch-load does NOT remember the never-
* -- opened name. All three (EDFILE6/EDSCR6/EDSCR6N) are
* -- build_ed_image.py's FIXTURES. --
PATH_EDFILE6 dfb 17
             asc '/mnt/MAUX/EDFILE6'
PATH_EDSCR6  dfb 16
             asc '/mnt/MAUX/EDSCR6'
PATH_EDOUT6  dfb 16
             asc '/mnt/MAUX/EDOUT6'
PATH_EDSCR6N dfb 17
             asc '/mnt/MAUX/EDSCR6N'
PATH_EDCAP6N dfb 17
             asc '/mnt/MAUX/EDCAP6N'

* SPAWN's path argument -- a liba string (high-bit, NUL-
* terminated), per the ratified spawn() ABI (docs/SYSCALL.md) --
* NOT an MLI pathname.
PATH_ED      asc   "/bin/ED"
             dfb   0

* -- session 6's argv[0]/argv[1] strings -- SAME liba-string
* -- shape as PATH_ED above (high-bit, NUL-terminated); these
* -- are what the kernel repacks into the child's ARGC/ARGV,
* -- per startup.equ and docs/SYSCALL.md item 13. AV_EDFILE6
* -- names the SAME file staged at PATH_EDFILE6; AV_EDNOSUCH
* -- deliberately names a path nothing creates.
AV_ED0       asc   "ED"
             dfb   0
AV_EDFILE6   asc   "/mnt/MAUX/EDFILE6"
             dfb   0
AV_EDNOSUCH  asc   "/mnt/MAUX/EDNOSUCH6"
             dfb   0

*---------------------------------------------------------------
* Session 7 call-site scratch.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 7 paths -- same MLI shape as edtestb.s's own PATH_*.
*---------------------------------------------------------------
PATH_EDSCR7  dfb 16
             asc '/mnt/MAUX/EDSCR7'
PATH_EDOUT7  dfb 16
             asc '/mnt/MAUX/EDOUT7'
PATH_EDFILE7 dfb 17
             asc '/mnt/MAUX/EDFILE7'

*---------------------------------------------------------------
* EDSCR7 content. Buffer: 6 lines, "BANK" on 1 and 3, "OLD..."
* on 5 and 6. Per-command trace:
*   //             -> "?"  no prior RE yet (dot stays 6, the
*                    last inserted line -- NOT a crash, and NOT
*                    "empty pattern matches everything")
*   /BANK/p        -> "BANK one"     forward search wraps from
*                    dot=6 to line 1; dot=1, LASTPAT="BANK"
*   //             -> "BANK three"   bare repeat reuses
*                    LASTPAT="BANK", finds the NEXT one from
*                    dot=1; dot=3 (PROVES forward `//` repeat)
*   /OLDthing/p    -> "OLDthing here"   forward search from
*                    dot=3; dot=5, LASTPAT="OLDthing"
*   g//p           -> "OLDthing here","OLDthing again"   g's
*                    empty search field reuses LASTPAT=
*                    "OLDthing" over its default 1,$ range,
*                    matching lines 5 and 6 (PROVES `g//` reuse
*                    -- the fourth call site)
*   5s/OLD/NEW/    -> (no output) line5 "OLDthing here" ->
*                    "NEWthing here"; dot=5, LASTPAT="OLD"
*   5p             -> "NEWthing here"
*   6s//XXX/       -> (no output) empty search field reuses
*                    LASTPAT="OLD"; line6 "OLDthing again" ->
*                    "XXXthing again"; dot=6 (PROVES `s//`
*                    reuse)
*   6p             -> "XXXthing again"
*   w /mnt/MAUX/EDFILE7, q
* EDSCR7 content is build_ed_image.py's FIXTURES.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 8 call-site scratch.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 8 paths -- same MLI shape as edtestb.s's own PATH_*.
*---------------------------------------------------------------
PATH_EDSCR8  dfb 16
             asc '/mnt/MAUX/EDSCR8'
PATH_EDOUT8  dfb 16
             asc '/mnt/MAUX/EDOUT8'
PATH_EDFILE8 dfb 17
             asc '/mnt/MAUX/EDFILE8'
PATH_EDFIX1  dfb 16
             asc '/mnt/MAUX/EDFIX1'

* -- FF1 (2026-09-06): "X" (1 char) would only ever overwrite
* -- CMDBUF[0..1], never reaching cmds' own start -- see
* -- edsub2.s's own GCMDBUF comment. 9 chars comfortably clears
* -- the "g/GONE/" (7-char) prefix. EDFIX1 content ("EDFIXLINE")
* -- is build_ed_image.py's FIXTURES.

*---------------------------------------------------------------
* EDSCR8 content -- the widened-g/v proof (2026-09-02,
* learning:01M1FX8HT89CKR9CB8T8VKCW1S). Buffer: 5 lines, "BANK"
* on 1, 3, 5. Per-command trace:
*   g/BANK/s/BANK/GONE/ -> (no output) the general dispatch
*                        path (not the old p/d-only scope) runs
*                        `s/BANK/GONE/` on each of lines 1,3,5
*                        -- "BANK one"->"GONE one", "BANK
*                        three"->"GONE three", "BANK five"->
*                        "GONE five"
*   ,p                  -> "GONE one","plain two","GONE
*                        three","plain four","GONE five"
*   g/plain/d           -> (no output) deletes lines matching
*                        "plain" (originally 2 and 4) --
*                        renumber-safety: after line 2 is
*                        deleted, the pending mark for the OLD
*                        line 4 must shift to 3 and still hit
*                        the right line (ED_GMARK_DEL, same
*                        discipline as excmd.s's EX_MARK_DEL)
*   ,p                  -> "GONE one","GONE three","GONE five"
*                        (3 lines, in order -- neither skipped
*                        nor doubled)
*   v/three/p           -> "GONE one","GONE five" (v's negated
*                        match -- the one line containing
*                        "three" is excluded)
*   g/GONE/g/x/p        -> "?" -- `g` may not appear inside
*                        cmds (the primary source's own
*                        restriction), refused BEFORE pass 1
*                        ever marks a line
*   ,p                  -> "GONE one","GONE three","GONE five"
*                        (SAME 3 lines -- proves the refusal
*                        above touched nothing)
*   g/GONE/u            -> "?" -- `u` may not appear inside
*                        cmds either, same refusal
*   ,p                  -> "GONE one","GONE three","GONE five"
*                        (unchanged again)
*   g/GONE/r EDFIX1     -> FF1 2026-09-06 (review): (no
*                        output) all THREE lines match "GONE".
*                        Classic ed `r` (no address) appends at
*                        $, re-evaluated fresh on each pass-2
*                        iteration -- match1 appends EDFIXLINE
*                        after line 3 ($=3 at that point, ->4
*                        lines); match2 (still line 2, untouched
*                        by an insert strictly after it) appends
*                        after the NEW $=4 (->5 lines); match3
*                        (still line 3) appends after $=5 (->6
*                        lines). With the GCMDBUF fix, pass 2's
*                        re-parse of "r EDFIX1" survives all
*                        three reads of EDFIX1's own 9-char line
*                        ("EDFIXLINE" -- long enough to reach
*                        cmds' own start in CMDBUF for a
*                        "g/GONE/" 7-char prefix, see edsub2.s).
*                        Pre-fix, match1's read into CMDBUF
*                        clobbers cmds before match2/3 ever
*                        re-parse it.
*   ,p                  -> "GONE one","GONE three","GONE five",
*                        "EDFIXLINE","EDFIXLINE","EDFIXLINE" (6
*                        lines, in order)
*   w /mnt/MAUX/EDFILE8, q
* EDSCR8 content is build_ed_image.py's FIXTURES.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 9 call-site scratch.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 9 paths -- same MLI shape as edtestb.s's own PATH_*.
*---------------------------------------------------------------
PATH_EDSCR9  dfb 16
             asc '/mnt/MAUX/EDSCR9'
PATH_EDOUT9  dfb 16
             asc '/mnt/MAUX/EDOUT9'
PATH_EDFILE9 dfb 17
             asc '/mnt/MAUX/EDFILE9'

*---------------------------------------------------------------
* EDSCR9 content -- `w` truncation proof (bug fix, 2026-09-02).
* Per-command trace (REWORKED 2026-09-06, EX4: `w PATH` no
* longer rebinds the remembered filename, so the second write
* now names EDFILE9 explicitly instead of riding a bare `w`'s
* old reuse of the first write's target -- same bytes land):
*   a / 6 long lines / .  -> builds a 6-line buffer, .=6
*   w /mnt/MAUX/EDFILE9 -> (no output) creates EDFILE9 fresh,
*                           writes all 6 long lines (90 bytes)
*   1,6d                  -> (no output) deletes the whole
*                           buffer, .=0
*   a / T1 / T2 / .       -> inserts 2 short lines after 0, .=2
*   w /mnt/MAUX/EDFILE9      -> (no output) explicit write
*                           overwrites EDFILE9 -- only 6 bytes
*                           ("T1"+CR+"T2"+CR). Pre-fix: ProDOS
*                           OPEN does not truncate, so EDFILE9's
*                           EOF stayed at 90 and the file kept
*                           84 stale bytes past the new content.
*                           Post-fix: SET_EOF(0) right after
*                           OPEN leaves EDFILE9 at exactly 6
*                           bytes.
*   q
* EDSCR9 content is build_ed_image.py's FIXTURES.
*---------------------------------------------------------------

*---------------------------------------------------------------
* Session 10 (XC1, 2026-09-06, second closing pass) --
* EX4's ED_RMBR_FNAME removal was unconditional, so an UNNAMED
* buffer's first `w` no longer established a current name either
* -- a bare launch (no argv, no `r`), then a first explicit `w`,
* then a bare second `w`, regressed. Trace:
*   a / old / .          -> one-line buffer, unnamed
*   w /mnt/MAUX/ED10FRESH   -> (no output) UNNAMED buffer -- the
*                          fix's conditional branch fires and
*                          establishes ED_CURFNAME here
*   1s/old/new/          -> (no output) buffer -> "new"
*   w                    -> (no output) bare `w` reuses the name
*                          just established above -- writes
*                          "new" to ED10FRESH, NOT refused
*   q
* Pre-fix (EX4's own unconditional removal), the bare `w` above
* found no remembered name and was refused (`?`, silent under
* stdin-script mode same as EDSCR4's cold case) -- ED10FRESH
* would stay at its FIRST-write content ("old"), not "new".
*---------------------------------------------------------------

PATH_EDSCR10 dfb 17
             asc '/mnt/MAUX/EDSCR10'
PATH_EDCAP10 dfb 17
             asc '/mnt/MAUX/EDCAP10'
PATH_EDFR10 dfb 19
               asc '/mnt/MAUX/ED10FRESH'

* EDSCR10 content (trace above) is build_ed_image.py's FIXTURES.

SESS10START
            lda   #31
            sta   R_STEP
* ---- EDSCR10 staged by build_ed_image.py (see session 1). ----

            lda   #<PATH_EDCAP10
            ldx   #>PATH_EDCAP10
            jsr   CRT_BY_PATH
            lda   #<PATH_EDCAP10
            ldx   #>PATH_EDCAP10
            jsr   OPEN_BY_PATH
            sta   S10OUTFD

            lda   #<PATH_EDSCR10
            ldx   #>PATH_EDSCR10
            jsr   OPEN_BY_PATH
            sta   S10INFD

            lda   #FDACT_DUP
            sta   FDA10
            lda   #FD_STDIN
            sta   FDA10+1
            lda   S10INFD
            sta   FDA10+2
            lda   #FDACT_DUP
            sta   FDA10+3
            lda   #FD_STDOUT
            sta   FDA10+4
            lda   S10OUTFD
            sta   FDA10+5
            stz   FDA10+6

            lda   #<FDA10
            sta   SFDAPTR
            lda   #>FDA10
            sta   SFDAPTR+1
            jsr   SPAWN_ED
            sta   R_SPAWN10_PID

            lda   #<R_SPAWN10_STA
            sta   WSTATUSPTR
            lda   #>R_SPAWN10_STA
            sta   WSTATUSPTR+1
            jsr   WAIT_ONE
            sta   R_WAIT10_PID

            lda   S10INFD
            jsr   CLOSE_FD
            lda   S10OUTFD
            jsr   CLOSE_FD

            lda   #<PATH_EDCAP10
            ldx   #>PATH_EDCAP10
            jsr   OPEN_BY_PATH
            sta   S10ARFD
            lda   S10ARFD
            sta   RFD
            lda   #<R_STAGE10O
            sta   RBUFPTR
            lda   #>R_STAGE10O
            sta   RBUFPTR+1
            lda   #8
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN10O
            lda   S10ARFD
            jsr   CLOSE_FD

            lda   #<PATH_EDFR10
            ldx   #>PATH_EDFR10
            jsr   OPEN_BY_PATH
            sta   S10BRFD
            lda   S10BRFD
            sta   RFD
            lda   #<R_STAGE10
            sta   RBUFPTR
            lda   #>R_STAGE10
            sta   RBUFPTR+1
            lda   #16
            sta   RMAXLEN
            stz   RMAXLEN+1
            jsr   READ_FD
            sta   R_LEN10
            lda   S10BRFD
            jsr   CLOSE_FD

            lda   #$AA
            sta   R_DONE
:donepark   bra   :donepark

PAR_PROC_LEN equ *-PARENT_PROC

*---------------------------------------------------------------
* Call-site scratch (KSPACE2, 2026-10-11): was 173 B of `ds`
* zeros spread through this file, emitted into the flat image.
* Now ONE dum block at the textual end (after PAR_PROC_LEN, so
* it overlays nothing -- learning:01M0FNC75R7YSFRNS328WHXMHN):
* the cells live in bank 1 just past the copied span, and
* PARENT_PROC's first instructions zero them, so every cell
* still starts at 0 exactly as the flat `ds` gave it.
*---------------------------------------------------------------
            dum   *
EDT_CELLS
S1OUTFD     ds    1
S1INFD      ds    1
S1RFD       ds    1
S2OUTFD     ds    1
S2INFD      ds    1
S2ARFD      ds    1
S2BRFD      ds    1
RFD         ds    1
RBUFPTR     ds    2
RMAXLEN     ds    2
SFDAPTR     ds    2
WSTATUSPTR  ds    2
FDA1        ds    7
FDA2        ds    7
S3OUTFD     ds    1
S3INFD      ds    1
S3ARFD      ds    1
S3BRFD      ds    1
FDA3        ds    7
S4OUTFD     ds    1
S4INFD      ds    1
S4ARFD      ds    1
FDA4        ds    7
S5OUTFD     ds    1
S5INFD      ds    1
S5ARFD      ds    1
S5BRFD      ds    1
FDA5        ds    7
S6OUTFD     ds    1
S6INFD      ds    1
S6ARFD      ds    1
S6BRFD      ds    1
FDA6        ds    7
AVPTR       ds    2       ;SPAWN_ED_A's own argv pointer, set by
                          ;each caller before the jsr
ARGV_ARR6   ds    6       ;argv[0]=AV_ED0, argv[1]=AV_EDFILE6,
                          ;NULL terminator
S6NOUTFD    ds    1
S6NINFD     ds    1
S6NCAPFD    ds    1
FDA6N       ds    7
ARGV_ARR6N  ds    6       ;argv[1]=AV_EDNOSUCH (a path that does
                          ;NOT exist -- the negative case)
CREATE_PARM    ds    12
CLOSE_PARM     ds    2
READ_PARM      ds    8
SPAWN_PARM     ds    8   ;path,argv,fdactions,envp (item 13c)
WAIT_PARM      ds    2
S7OUTFD     ds    1
S7INFD      ds    1
S7ARFD      ds    1
S7BRFD      ds    1
FDA7        ds    7
S8OUTFD     ds    1
S8INFD      ds    1
S8ARFD      ds    1
S8BRFD      ds    1
FDA8        ds    7
S9OUTFD     ds    1
S9INFD      ds    1
S9ARFD      ds    1
S9BRFD      ds    1
FDA9        ds    7
S10OUTFD    ds    1
S10INFD     ds    1
S10ARFD     ds    1
S10BRFD     ds    1
FDA10       ds    7
EDT_CELLS_END
            dend
