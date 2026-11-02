*---------------------------------------------------------------
* playtestb.s -- image body for playtest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


R_SH_PID        equ $1200
R_WAIT_PID      equ $1201
R_SH_STATUS     equ $1202
R_DONE          equ $1210
R_ERR           equ $1211
R_STEP          equ $1212
* -- INIT (docs/COVER-OFF.md sec 1). pid 1 respawns the console
* -- shell instead of parking, so `exit` at the prompt is no
* -- longer the end of the session. Observable by a gate:
R_RESPAWN       equ $1213      ;shells started after the first
R_FAST          equ $1214      ;too-fast exits in a row
R_T0            equ $1215      ;tick count at the last spawn
R_TMODE         equ $1217      ;K_TIMER_MODE as SYS_TICK reports
R_RCPID         equ $1218      ;pid /etc/rc got, 0 = none
R_RCDONE        equ $1219      ;boot script: a ONE-SHOT
R_BACKOFF       equ $121A      ;back-offs taken (flaps survived)
R_ISSLEN        equ $121E      ;bytes of /etc/issue printed
ISS_BUF         equ $1100      ;its read buffer, 255 bytes
R_SPIN          equ $121B      ;no-tick back-off: syscall count
INIT_FLAPT      equ 120        ;ticks; 2 s at 60 Hz
INIT_FLAPN      equ 5          ;that many in a row = back off
INIT_COOPN      equ 16         ;same, when there is no tick
INIT_BACKH      equ 3          ;back-off = this many x 256 ticks
                               ;(768 ticks, 12.8 s at 60 Hz)
INIT_POLLH      equ 200        ;poll ceiling: x 256 syscalls

* -- HOLD/READY/GO handshake (docs/CONSOLE.md section 6/11b, --
* 2026-08-19), so check_play.py can assert the boot-time --
* TTY_VT_SUITE battery cell by cell BEFORE the post-battery --
* clear (Fix 1) erases them. Fixed addresses in MAIN memory --
* -- ENTRY runs before any process/aux-bank switching, same as
* -- TTY_VT_SUITE itself, so these must be readable/pokeable by
* a -- harness before the FIRST emulator step, surviving
* ProDOS's -- own boot + BRUN of this SYSTEM file. $9300 follows
* the -- bankcopytest/writelanding precedent
* (scripts/check_bankcopy.py, --
* scripts/experiment_writelanding.py) and was independently --
* re-verified for THIS image/boot path (full ProDOS, not a raw
* -- block-0 loader): poked before the first step, it still
* reads -- back unchanged at the shell prompt.
*
* MOVED $9300 -> $97FC, 2026-09-20, and the reason is the whole
* point of this block. This image loads FLAT from $2000 and its
* sanctioned ceiling is PMLI_IBF_BASE ($9800) -- 30,720 B. The
* handshake sat at $9300, which is 29,440 B in, i.e. INSIDE the
* image's own growth room and 107 B above where the image
* actually ended. So ~100 B of new code in this file loaded
* OVER the magic the gate had poked, the pause never engaged,
* and FIFTEEN gates went red on BOTH hosts with `timed out
* waiting for TTY_VT_SUITE checkpoint (READY)` -- naming a
* battery that had nothing to do with it. Nothing gated the
* collision, because 30,720 was the only ceiling anyone had
* written down.
*
* At $97FC the four bytes are the LAST four below the ceiling,
* so the only image that can reach them is one that is already
* over budget -- and check_kernel_images.py fails that image
* first, by name. The two limits are now the same limit.
* MOVED $97E8-$97FF -> $9FE8-$9FFF, 2026-10-21 (B1): the pool
* went to $A000, so the block is again the last bytes below it.
PT_HOLD         equ $9FE8      ;gate pokes the TWO-BYTE magic
PT_HOLD2        equ $9FEB      ;$C5/$AA (HOLD and HOLD2) before
                               ;the first step to pause after
                               ;TTY_VT_SUITE; anything else
                               ;(default -- real play, MAME,
                               ;AppleWin) = no pause, boot
                               ;clears immediately. Two exact
                               ;bytes, not "nonzero": cold
                               ;hardware with randomized RAM
                               ;must not wander into a GO-less
                               ;spin (1/65536 vs a coin flip per
                               ;bit pattern)
PT_HOLD_MAG1    equ $C5
PT_HOLD_MAG2    equ $AA
PT_READY        equ $9FE9      ;boot writes $55 here once paused
                               ;and waiting for GO
PT_GO           equ $9FEA      ;gate pokes $5A here, after
                               ;running its battery asserts, to
                               ;release the boot into the clear
                               ;+ sh spawn

* -- Same two-exact-byte poke pattern as HOLD, two more knobs
* -- (S3 console gates, 2026-08-23):
* -- N80: check_play80n.py pokes $E8/$1C before the first step;
* -- ENTRY then requests the NATIVE 80-column backend
* -- (TTY_BKND_REQ=2) before PRC_INIT runs TTY_INIT. Default
* -- (no poke) keeps auto selection, so check-play/check-play80
* -- see exactly the image they always saw.
* -- VC: check_vc.py pokes $7A/$B3; ENTRY then runs VC_SUITE --
* -- the per-console state roundtrip -- right after
* -- TTY_VT_SUITE, parking its verdict at R_VC_DONE for the
* -- gate to peek.
PT_N80          equ $9FEC
PT_N80B         equ $9FED
PT_N80_MAG1     equ $E8
PT_N80_MAG2     equ $1C
PT_VC           equ $9FEE
PT_VC2          equ $9FEF
PT_VC_MAG1      equ $7A
PT_VC_MAG2      equ $B3
R_VC_DONE       equ $9FF8      ;$66 = suite passed, $99 = failed
* -- F40: check_play.py / check_vc.py poke $F4/$0A before the
* -- first step; ENTRY then FORCES 40 columns (TTY_BKND_REQ=1).
* -- Auto boots the best surface present since 2026-09-03 (the
* -- card, else built-in 80), and those gates assert 40 cols.
PT_F40          equ $9FF0
PT_F40B         equ $9FF1
PT_F40_MAG1     equ $F4
PT_F40_MAG2     equ $0A
R_VC_ERR        equ $9FF9      ;failing step number on $99
R_VC_STEP       equ $9FFA      ;progress marker
R_VC_CK         equ $9FFC      ;live checksum lo/hi
R_VC_CKA        equ $9FFE      ;expected checksum lo/hi

SH_PATH         equ $1000
SH_ARG0         equ SH_PATH+5  ;the "sh",0 tail of the path
SPAWN_PARM      equ $1040
WAIT_PARM       equ $1050
ARGV_ARR        equ $1060
TICK_PARM       equ $1070
TICK_BUF        equ $1078
RC_PATH         equ $1090      ;[len][chars][0]: the MLI form
                               ;at +0, the spawn form at +1
RC_ARGP         equ $1091      ;== RC_PATH+1, spelled out: no
                               ;expression, no precedence doubt
RC_OPARM        equ $10A0      ;MLI OPEN parmlist (+5 = refnum)
RC_PCOPEN       equ 3          ;inc/mli.equ PCOUNT_OPEN
RC_PCCLOSE      equ 1          ;inc/mli.equ PCOUNT_CLOSE
IDLE_BANK       ds 1

*-- The two boot copies are one routine: main memory at SRC to
*-- the SAME address in a process bank (A = the bank), length in
*-- K_BC_LEN. (They were two copies of the same 14 stores; the
*-- bytes paid for init's second message.)
BOOT_CPY_PAR
            lda   #<PARENT_PROC
            sta   K_BC_SRCADDR
            lda   #>PARENT_PROC
            sta   K_BC_SRCADDR+1
            lda   #<PAR_PROC_LEN
            sta   K_BC_LEN
            lda   #>PAR_PROC_LEN
            sta   K_BC_LEN+1
            lda   #1
            bra   BOOT_CPY

BOOT_CPY_IDLE
            lda   #<IDLE_PROC
            sta   K_BC_SRCADDR
            lda   #>IDLE_PROC
            sta   K_BC_SRCADDR+1
            lda   #<IDLE_PROC_LEN
            sta   K_BC_LEN
            lda   #>IDLE_PROC_LEN
            sta   K_BC_LEN+1
            lda   IDLE_BANK

BOOT_CPY    sta   K_BC_DSTBANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   K_BC_SRCADDR
            sta   K_BC_DSTADDR
            lda   K_BC_SRCADDR+1
            sta   K_BC_DSTADDR+1
            stz   K_BC_SRCBANK
            jmp   BankCopy

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

PATCH_IDL_FRM
            lda   IDLE_BANK
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #<IDLE_PROC
            sta   $01FE
            lda   #>IDLE_PROC
            sta   $01FF
            sta   ALTZPMAIN
            rts

ENTRY       sei
            cld
            ldx   #$FF
            txs

            jsr   INSTALL_COPY
            jsr   SCH_INIT
            jsr   TIMER_PROBE
* -- wire up `bye` (entry.s K_BYE_VEC comment, kbye.s's own
* -- header): playtest is the one image that actually calls
* -- SYS_BYE (check-bye's own target), so it is the one image
* -- that overwrites the K_BYE_VEC default -- with K_BYE_TRAMP's
* -- address, not PRC_BYE's own (PRC_BYE is segment-resident).
* -- INLINED 2026-09-27 (coordinator review, budget trim):
* -- PRC_BYE_INIT had exactly one caller (here); a `jsr`+`rts`
* -- round a 4-line body was pure overhead.
            lda   #<K_BYE_TRAMP
            sta   K_BYE_VEC
            lda   #>K_BYE_TRAMP
            sta   K_BYE_VEC+1
* -- N80 knob: must land BEFORE PRC_INIT, whose TTY_INIT reads
* -- TTY_BKND_REQ exactly once.
            lda   PT_N80
            cmp   #PT_N80_MAG1
            bne   :non80
            lda   PT_N80B
            cmp   #PT_N80_MAG2
            bne   :non80
            lda   #2
            sta   TTY_BKND_REQ             ;force native 80-col
:non80      lda   PT_F40
            cmp   #PT_F40_MAG1
            bne   :nof40
            lda   PT_F40B
            cmp   #PT_F40_MAG2
            bne   :nof40
            lda   #1
            sta   TTY_BKND_REQ             ;force 40-col (gates)
:nof40
            jsr   PRC_INIT
            lda   #<PRC_INTR_SWP           ;^C kill sweep --
            sta   K_INTR_HOOK              ;see sched.s's
            lda   #>PRC_INTR_SWP           ;K_INTR_HOOK cell
            sta   K_INTR_HOOK+1
            lda   #<PRC_STOP_SWP           ;^Z suspend sweep --
            sta   K_STOP_HOOK              ;its twin (docs/JOB-
            lda   #>PRC_STOP_SWP           ;CONTROL.md Incr. B)
            sta   K_STOP_HOOK+1
            jsr   TTY_VT_SUITE

* -- VC knob: the per-console state roundtrip, only when the
* -- gate asked for it. Pure state manipulation -- writes
* -- nothing to the screen, and puts vc0 back reset, so the
* -- boot continues identically either way.
            lda   PT_VC
            cmp   #PT_VC_MAG1
            bne   :novc
            lda   PT_VC2
            cmp   #PT_VC_MAG2
            bne   :novc
            jsr   VC_SUITE
:novc

* -- Fix 1 (docs/CONSOLE.md 11b): clear the VT battery's crud
* off -- the screen before sh spawns. HOLD lets a harness pause
* right -- here, with the battery still on screen, to assert it
* cell by -- cell before the clear erases it -- see the
* PT_HOLD/READY/GO -- comment above.
            lda   PT_HOLD
            cmp   #PT_HOLD_MAG1
            bne   :noholdpause
            lda   PT_HOLD2
            cmp   #PT_HOLD_MAG2
            bne   :noholdpause
            lda   #$55
            sta   PT_READY
:waitgo     lda   PT_GO
            cmp   #$5A
            bne   :waitgo
:noholdpause
            jsr   TTY_CLR_SCRN

            lda   #1
            jsr   PRC_STMP_BANK
            lda   #1
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_PAR_FRM
            jsr   BOOT_CPY_PAR

            lda   #1
            ldx   #1
            jsr   SCH_CREATE

            jsr   PRC_ALLC_BANK
            bcc   :idlebank
            lda   #$EE
            sta   R_DONE
            jmp   *
:idlebank   sta   IDLE_BANK
            jsr   PRC_STMP_BANK
            lda   IDLE_BANK
            jsr   PRC_SYNTH_FRM
            jsr   PATCH_IDL_FRM
            jsr   BOOT_CPY_IDLE
            lda   IDLE_BANK
            tax
            jsr   SCH_CREATE
            lda   IDLE_BANK
            sta   K_IDLE_PID          ;lowest priority (sched.s)
            jsr   SCH_START

*---------------------------------------------------------------
* TTY_VT_SUITE -- the dedicated escape-sequence battery
* docs/CONSOLE.md section 6 names as the gate on growing the
* parser a layer (logical screen buffer, inactive virtual
* consoles). It runs once at boot, before the shell starts, and
* writes at CSI rows 3-10 and 21-23 (physical rows 2-9 and
* 20-22 as of the 2026-09-03 row-0 reclaim: the CSI row param
* is now decremented like the column, so ESC[1;1H is row 0).
* CSI rows 1-2 (physical 0-1) are left alone because the shell
* prompt lands there and would scroll over any assertion placed
* in its path; scripts/check_play.py reads every cell below
* BEFORE typing.
*
* The battery is deliberately positional: each case parks the
* cursor at a known row/column and writes a distinctive glyph,
* so a failure names the exact escape that misbehaved instead of
* "the screen looks wrong".
*
* The index is over 16 bits: the sequence is now well past 256
* bytes.
*---------------------------------------------------------------
TTY_VT_SUITE
            lda   #<TTY_VT_SEQ
            sta   VT_PTR
            lda   #>TTY_VT_SEQ
            sta   VT_PTR+1
            lda   #<TTY_VTSEQ_LEN
            sta   VT_REMAIN
            lda   #>TTY_VTSEQ_LEN
            sta   VT_REMAIN+1
:put        lda   VT_REMAIN
            ora   VT_REMAIN+1
            beq   :done
            ;-- VT_PTR is the authority; P_PTR1 is only borrowed
            ;for the
            ;-- indirect read (it must be zero page) and is
            ;reloaded every
            ;-- pass because TTY_PUT_BYTE can reach TTY_SCROLL,
            ;which owns
            ;-- P_PTR1 too. Read BEFORE the call, never after.
            lda   VT_PTR
            sta   P_PTR1
            lda   VT_PTR+1
            sta   P_PTR1+1
            ldy   #0
            lda   (P_PTR1),y
            jsr   TTY_PUT_BYTE
            inc   VT_PTR
            bne   :nohi
            inc   VT_PTR+1
:nohi       lda   VT_REMAIN
            bne   :nolo
            dec   VT_REMAIN+1
:nolo       dec   VT_REMAIN
            bra   :put
:done       rts

VT_PTR      ds    2
VT_REMAIN   ds    2

TTY_VT_SEQ
            dfb   $1B
            asc   "[2J"
* -- absolute positioning (H), row 3: 'A' at col 4, 'B' at col 5
* --
            dfb   $1B
            asc   "[3;5H"
            asc   "AB"
* -- 'f' as the documented alias for 'H', row 3: 'f' at col 20
* --
            dfb   $1B
            asc   "[3;21f"
            asc   "f"
* -- relative moves (D then C), row 4. Park at col 9, back 3 ->
* col 6 'L'; -- that write advances to col 7, forward 2 -> col 9
* 'R'.
            dfb   $1B
            asc   "[4;10H"
            dfb   $1B
            asc   "[3D"
            asc   "L"
            dfb   $1B
            asc   "[2C"
            asc   "R"
* -- relative-move CLAMPING, row 5. 9 left from col 1 must clamp
* to col 0, -- not wrap or underflow; 'C' lands at col 0.
            dfb   $1B
            asc   "[5;2H"
            dfb   $1B
            asc   "[9D"
            asc   "C"
* -- vertical moves (B then A), rows 6/7. Down 2 from row 5 ->
* row 7 'D'; -- then up 1 -> row 6 'U' at col 10.
            dfb   $1B
            asc   "[5;11H"
            dfb   $1B
            asc   "[2B"
            asc   "D"
            dfb   $1B
            asc   "[1A"
            asc   "U"
* -- erase-to-end-of-line (K), row 8. Fill cols 0-9, then erase
* from col 4: -- cols 0-3 must survive, cols 4+ must go blank.
            dfb   $1B
            asc   "[8;1H"
            asc   "0123456789"
            dfb   $1B
            asc   "[8;5H"
            dfb   $1B
            asc   "[K"
* -- SGR with TWO parameters, row 9. "reset, then inverse" in
* one sequence: -- 'I' must be inverse ($09), 'N' normal after
* an explicit SGR 27.
            dfb   $1B
            asc   "[9;1H"
            dfb   $1B
            asc   "[0;7m"
            asc   "I"
            dfb   $1B
            asc   "[27m"
            asc   "N"
* -- TAB, row 10. From col 0 a tab must land the next glyph on
* col 8.
            dfb   $1B
            asc   "[10;1H"
            dfb   $09
            asc   "T"
* -- an UNKNOWN final byte must terminate the sequence and not
* wedge the -- parser: 'OK' has to reach the screen at row 10
* cols 16/17.
            dfb   $1B
            asc   "[10;17H"
            dfb   $1B
            asc   "[9Z"
            asc   "OK"
            dfb   $1B
            asc   "[22;1H"
            asc   "A"
            dfb   $1B
            asc   "[7m"
            asc   "B"
            dfb   $1B
            asc   "[0m"
            asc   "C"
            dfb   $1B
            asc   "[23;1H"
            dfb   $1B
            asc   "[K"
            asc   "Z"
* ESC 7 / ESC 8 across an intervening CSI. The save stash must
* survive a sequence that re-runs the CSI parameter parser --
* the first cut of this code stashed into TTY_CSI_ROW/COL, which
* TTY_CSI_START zeroes, so the canonical save/move/restore idiom
* silently restored the wrong cell. 'S' must land at row 21 col
* 0 ($06D0), NOT at the row-23 move target.
            dfb   $1B
            asc   "[21;1H"
            dfb   $1B
            asc   "7"
            dfb   $1B
            asc   "[23;4H"
            dfb   $1B
            asc   "8"
            asc   "S"
            dfb   $1B
            asc   "[1;1H"
TTY_VTSEQ_LEN equ *-TTY_VT_SEQ

IDLE_PROC
            bra   IDLE_PROC
IDLE_PROC_LEN equ   *-IDLE_PROC
PARENT_PROC bra   PT_EQHOP
*-- The pathname/label data lives INSIDE the staged parent
*-- span, right behind the entry hop: pid 1 executes a COPY
*-- of [PARENT_PROC..+PAR_PROC_LEN] in its own bank, so data
*-- outside the span reads as never-copied garbage there --
*-- found the hard way on this very edit. The hop keeps the
*-- entry at PARENT_PROC; the placement keeps every *_LEN
*-- equ defined before its immediate use (S9 EQU burn-down
*-- 2026-08-29).
SHBIN_PTH_TXT
            asc   "/bin/sh"
SHBIN_PTH_LEN equ *-SHBIN_PTH_TXT
RCPTH_TXT
            dfb   7              ;MLI length byte, then the name
            asc   "/etc/rc"
RCPTH_LEN equ *-RCPTH_TXT
ISSPTH_TXT
            dfb   10
            asc   '/etc/issue'
ISSPTH_LEN equ *-ISSPTH_TXT
TTYPTH_TXT
            dfb   8              ;the controlling terminal
            asc   '/dev/tty'
MSGF_TXT
            asc   'init: shell failed, retrying'
*-- ESC E (NEL), not a bare CR: a CR is a newline only under
*-- OPOST, and a full-screen program may have left the console
*-- raw (KFIX8: the next prompt then overprinted this line's
*-- head). NEL is column 0 + index in either mode (TT9_NEL).
            dfb   $9B,$C5
MSGF_LEN    equ   *-MSGF_TXT
PT_EQHOP
            stz   R_ERR
            stz   R_STEP
            jsr   SETUP_SH

            stz   R_RESPAWN
            stz   R_FAST
            stz   R_RCPID
            stz   R_BACKOFF
            stz   R_ISSLEN
            jsr   INIT_ISSUE
            jsr   INIT_RC

*-- INIT'S LOOP (docs/COVER-OFF.md sec 1). pid 1 used to spawn
*-- the shell, wait for it, and park. That made `exit` at the
*-- console prompt the end of the session: measured 2026-09-20,
*-- the kernel and scheduler kept running, the tty kept echoing,
*-- and nothing would ever execute a program again. There is no
*-- other init to fall back on, so this IS it.
*-- The rate limit is not decoration: a shell that dies the
*-- instant it starts would otherwise spin the machine spawning
*-- it. Time is measured with SYS_TICK, whose MODE byte has to
*-- be honoured -- in TIMER_MD_COOP the counter is FROZEN, not
*-- slow, so elapsed time cannot be measured at all there and a
*-- plain cap is the only honest fallback.
:ptrelau    jsr   INIT_T0

            lda   #1
            sta   R_STEP
            jsr   SPAWN_SH
            bcc   :ptspawn
*-- A SPAWN THAT FAILS IS NOT A REASON TO LEAVE EITHER (/bin/sh
*-- renamed, the volume gone for a moment, no free bank): this
*-- parked at P_ERR ($EE) and the console was lost for good, the
*-- same end as flapping. Say so, wait, try again. The error
*-- code stays in R_ERR for a gate; R_STEP stays 1.
            sta   R_ERR
            jsr   INIT_BACKOFF
            bra   :ptrelau
:ptspawn    sta   R_SH_PID

:ptwaitl    lda   #2
            sta   R_STEP
            jsr   WAIT_SH
            bcc   :ptwait
            jmp   P_ERR
*-- WAIT RETURNS ANY CHILD, and init now has two kinds. Only
*-- the console shell is respawned; the boot script exiting is
*-- the normal end of its life and must not be mistaken for a
*-- shell that died.
:ptwait     sta   R_WAIT_PID
            cmp   R_SH_PID
            bne   :ptwaitl

            lda   #$AA
            sta   R_DONE
            jsr   INIT_RATE            ;carry set = flapping
            bcc   :ptagain
*-- FLAPPING IS A REASON TO WAIT, NOT TO LEAVE. It used to park
*-- here ($E5, `bra *`): nothing ever ran on the console again,
*-- and a shell that died five times fast -- a retained bank
*-- that
*-- BRKs, a bad /bin/sh -- cost the whole session. Unix inits
*-- said "respawning too rapidly" and tried again later; so does
*-- this one. The rate limit still holds: at most INIT_FLAPN
*-- spawns per back-off.
            jsr   INIT_BACKOFF
*-- counted AFTER the decision, so the counter means "shells
*-- this init actually restarted" and not "times it considered
*-- it" -- a gate that reads it can then tell a respawn from a
*-- back-off (check-init's teeth run, 2026-09-20).
:ptagain    inc   R_RESPAWN
            bra   :ptrelau

P_ERR       sta   R_ERR
            lda   #$EE
            sta   R_DONE
:park       bra   :park

SETUP_SH
            ldx   #0
:cp         lda   SHBIN_PTH_TXT,x
            sta   SH_PATH,x
            inx
            cpx   #SHBIN_PTH_LEN
            bne   :cp
            stz   SH_PATH+SHBIN_PTH_LEN

            rts


SPAWN_SH    lda   #<SH_ARG0
            sta   ARGV_ARR
            lda   #>SH_ARG0
            sta   ARGV_ARR+1
            stz   ARGV_ARR+2
            stz   ARGV_ARR+3

            lda   #<SH_PATH
            sta   SPAWN_PARM
            lda   #>SH_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+4
            stz   SPAWN_PARM+5
            stz   SPAWN_PARM+6           ;NULL envp
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            rts

WAIT_SH     lda   #<R_SH_STATUS
            sta   WAIT_PARM
            lda   #>R_SH_STATUS
            sta   WAIT_PARM+1
            lda   #<WAIT_PARM
            ldx   #>WAIT_PARM
            ldy   #SYS_WAIT
            jsr   $FF00
            rts

*---------------------------------------------------------------
* INIT_T0 / INIT_RATE -- the respawn rate limit. INIT_T0 samples
* SYS_TICK before a spawn; INIT_RATE samples it after the wait
* and returns CARRY SET when the shell has exited too fast, too
* many times in a row. Both live inside the PARENT_PROC span:
* pid 1 runs a COPY of that span, and a jsr outside it lands
* in never-copied garbage.
*---------------------------------------------------------------
*---------------------------------------------------------------
* INIT_RC -- run /etc/RC once, if it is there.
*
* Spawns the SHELL on it (`sh SCRIPTFILE`, shlex.s's ARGC==2
* form) rather than interpreting anything here: that buys the
* whole shell language for a boot script at the cost of one
* argv slot, and it is what /etc/rc has always been.
*
* A missing file is the NORMAL case and is silent -- most disks
* will not have one. R_RCPID records the pid so a gate can tell
* "init spawned it" from "init never tried".
*
* RUN TO COMPLETION BEFORE THE CONSOLE SHELL, and that ordering
* is load-bearing for the HARNESS, not for the machine. The
* first version started the shell first so an rc could `chvt 1`
* back at the end; the cost was a transient extra process alive
* at the moment the prompt appears, and four gates that snapshot
* the live pid set right after boot began failing on a race they
* could not see. "A prompt is on the glass" has to keep meaning
* "the machine has finished starting". An rc that opens a
* console now simply ends there; Option-1 comes back.
*
* NOT /etc/profile, deliberately: a profile is sourced by every
* interactive shell, which would re-run it on each console chvt
* opens. Warming the machine is a once-per-boot job and this is
* where Unix has always put it.
*---------------------------------------------------------------
INIT_RC     ldx   #0
:rccp       lda   RCPTH_TXT,x
            sta   RC_PATH,x
            inx
            cpx   #RCPTH_LEN
            bne   :rccp
            stz   RC_PATH+RCPTH_LEN
*-- IS THERE ONE? A bare spawn would load the SHELL -- 26 KB off
*-- the disk -- only for it to fail to open the script and exit,
*-- on every boot of every image that has no rc. That is what
*-- timed four gates out when this was first written: they wait
*-- a fixed budget for a prompt, and the prompt was now behind a
*-- whole shell load. One failed OPEN is the cheap question, and
*-- a disk with no boot script is the common case.
            lda   #<RC_PATH            ;the LENGTH-prefixed form
            ldx   #>RC_PATH
            jsr   INIT_OPEN
            bcs   :rcnone               ;no boot script: normal
            sta   RC_OPARM+1            ;found: hand it back
            jsr   INIT_CLOSE
            lda   #<SH_ARG0             ;argv[0] = "sh"
            sta   ARGV_ARR
            lda   #>SH_ARG0
            sta   ARGV_ARR+1
            lda   #<RC_ARGP             ;argv[1] = the NUL-term
            sta   ARGV_ARR+2             ;form, one past the MLI
            lda   #>RC_ARGP              ;length byte
            sta   ARGV_ARR+3
            stz   ARGV_ARR+4
            stz   ARGV_ARR+5
            lda   #<SH_PATH             ;still /bin/sh
            sta   SPAWN_PARM
            lda   #>SH_PATH
            sta   SPAWN_PARM+1
            lda   #<ARGV_ARR
            sta   SPAWN_PARM+2
            lda   #>ARGV_ARR
            sta   SPAWN_PARM+3
            stz   SPAWN_PARM+4
            stz   SPAWN_PARM+5
            stz   SPAWN_PARM+6
            stz   SPAWN_PARM+7
            lda   #<SPAWN_PARM
            ldx   #>SPAWN_PARM
            ldy   #SYS_SPAWN
            jsr   $FF00
            bcs   :rcnone               ;no RC file: normal
            sta   R_RCPID
*-- Wait for it. Its own children (a shell chvt opened on
*-- another console) are NOT ours and are not waited for -- they
*-- outlive it as orphans, which is the point of opening them.
:rcwait     jsr   WAIT_SH
            bcs   :rcnone
            cmp   R_RCPID
            bne   :rcwait
:rcnone     rts

*---------------------------------------------------------------
* INIT_ISSUE -- print /etc/issue on the console, once per boot,
* if it is there. V7 has getty do this; maux has no getty and a
* sample /etc/rc is not an option (rc costs a whole `sh` spawn
* before the first prompt), so pid 1 does it with three
* syscalls and no child. Read once, 255 bytes at most, and
* written raw: the file carries its own line ends. A missing
* file is the normal case and silent. R_ISSLEN records how
* many bytes went out, for a gate.
*---------------------------------------------------------------
INIT_ISSUE  ldx   #0
:isscp      lda   ISSPTH_TXT,x
            sta   RC_PATH,x
            inx
            cpx   #ISSPTH_LEN
            bne   :isscp
            stz   RC_PATH+ISSPTH_LEN
            lda   #<RC_PATH
            ldx   #>RC_PATH
            jsr   INIT_OPEN
            bcs   :issout
            sta   RC_OPARM+1
            lda   #<ISS_BUF
            sta   RC_OPARM+2
            lda   #>ISS_BUF
            sta   RC_OPARM+3
            lda   #$FF
            sta   RC_OPARM+4
            stz   RC_OPARM+5
            stz   RC_OPARM+6
            stz   RC_OPARM+7
            lda   #4
            sta   RC_OPARM
            ldy   #SYS_READ
            jsr   INIT_RCSYS
*-- the count is read whatever the carry says: a file shorter
*-- than the request ends in EOF, with the bytes already moved.
            lda   RC_OPARM+6
            sta   R_ISSLEN
            jsr   INIT_CLOSE
            lda   R_ISSLEN
            beq   :issout
            lda   #<TTYPTH_TXT
            ldx   #>TTYPTH_TXT
            jsr   INIT_OPEN
            bcs   :issout
            sta   RC_OPARM+1
            lda   #<ISS_BUF
            sta   RC_OPARM+2
            lda   #>ISS_BUF
            sta   RC_OPARM+3
            lda   R_ISSLEN
            sta   RC_OPARM+4
            stz   RC_OPARM+5
            lda   #4
            sta   RC_OPARM
            ldy   #SYS_WRITE
            jsr   INIT_RCSYS
            jsr   INIT_CLOSE
:issout     rts

INIT_TICK   lda   #<TICK_BUF
            sta   TICK_PARM
            lda   #>TICK_BUF
            sta   TICK_PARM+1
            lda   #<TICK_PARM
            ldx   #>TICK_PARM
            ldy   #SYS_TICK
            jsr   $FF00
            rts

INIT_T0     jsr   INIT_TICK
            lda   TICK_BUF             ;+0 = K_TIMER_MODE
            sta   R_TMODE
            lda   TICK_BUF+1           ;+1..+4 = 32-bit count LE
            sta   R_T0
            lda   TICK_BUF+2
            sta   R_T0+1
            rts

INIT_RATE   lda   R_TMODE
            cmp   #3                   ;TIMER_MD_COOP: no
            bne   :irtimed             ;hardware source, so the
            inc   R_FAST               ;counter is FROZEN and a
            lda   R_FAST               ;delta always reads zero:
            cmp   #INIT_COOPN          ;count respawns instead
            bcs   :irgive
            bra   :irok
:irtimed    jsr   INIT_ELAPSED
            bne   :irslow              ;>= 256 ticks: plenty
            cpx   #INIT_FLAPT
            bcs   :irslow
            inc   R_FAST
            lda   R_FAST
            cmp   #INIT_FLAPN
            bcs   :irgive
            bra   :irok
:irslow     stz   R_FAST
:irok       clc
            rts
:irgive     sec
            rts

* INIT_ELAPSED -- ticks since INIT_T0: A = high byte (Z set when
* zero), X = low byte.
INIT_ELAPSED
            jsr   INIT_TICK
            sec
            lda   TICK_BUF+1
            sbc   R_T0
            tax
            lda   TICK_BUF+2
            sbc   R_T0+1
            rts

*---------------------------------------------------------------
* INIT_BACKOFF -- the console shell is dying as fast as it can
* be
* started, or cannot be started at all. Say so on the console,
* wait, forget the count, and let the caller try again. R_DONE
* reads $E5 for the duration.
*
* WHAT THE KERNEL OFFERS (measured 2026-10-18, KFIX7-NOTES
* sec 1): no timed sleep and no yield syscall. Every blocking
* call wakes on an event (a key, a pipe, a child), never on a
* deadline,
* and SCH_YIELD has no syscall. So with a tick the wait POLLS
* SYS_TICK, exactly as /bin/sleep does; the scheduler
* preempts it
* at quantum and the idle process is lower priority, so it costs
* what a runnable process costs and no more. With NO advancing
* tick (COOP, a forced mode, a failed re-arm) the same loop ends
* on a fixed count of syscalls instead.
*---------------------------------------------------------------
INIT_BACKOFF
            lda   #$E5                 ;distinct from $AA (ran)
            sta   R_DONE               ;and $EE (syscall error)
            inc   R_BACKOFF
*-- INIT HAS NO CONSOLE FD (its table is empty; a child gets the
*-- console by default), so it opens the controlling terminal
*-- for
*-- the length of the back-off and closes it again -- an fd left
*-- in init's table would be inherited by every shell it spawns.
*-- A failed OPEN needs no branch: the WRITE and CLOSE below
*-- would fail with it, and a machine with no console has nobody
*-- to tell. The back-off itself must still happen.
            lda   #<TTYPTH_TXT
            ldx   #>TTYPTH_TXT
            jsr   INIT_OPEN
            sta   RC_OPARM+1           ;the fd, kept for CLOSE
            lda   #<MSGF_TXT
            sta   RC_OPARM+2
            lda   #>MSGF_TXT
            sta   RC_OPARM+3
            lda   #MSGF_LEN
            sta   RC_OPARM+4
            stz   RC_OPARM+5
            lda   #4
            sta   RC_OPARM
            ldy   #SYS_WRITE
            jsr   INIT_RCSYS
            jsr   INIT_T0              ;the clock, now
            stz   R_SPIN
            stz   R_SPIN+1
*-- THE POLL HAS A CEILING. A counter that does not advance (no
*-- tick source at all, or a mode set with no IRQ armed behind
*-- it: K_TIMER_FORCE, a re-arm that failed after `bye`) never
*-- reaches INIT_BACKH, and an unbounded poll is the old park in
*-- another form. And a key cannot end the wait: keyboard
*-- polling rides the tick hook, so with no tick the console
*-- takes no input at all (docs/KFIX7-NOTES.md sec 1). So every
*-- iteration is also counted, and a fixed number of syscalls
*-- ends the wait either way. INIT_POLLH is far above what 12.8
*-- s of ticks costs at stock speed, so a live tick always
*-- ends it first.
:ibpoll     jsr   INIT_ELAPSED
            cmp   #INIT_BACKH
            bcs   :ibdone
            inc   R_SPIN
            bne   :ibpoll
            inc   R_SPIN+1
            lda   R_SPIN+1
            cmp   #INIT_POLLH
            bcc   :ibpoll
:ibdone     jsr   INIT_CLOSE
            stz   R_FAST
            lda   #$AA
            sta   R_DONE
            rts

* INIT_OPEN -- A,X = a LENGTH-prefixed path: MLI OPEN it with no
* io_buffer. Carry set = failed; else A = refnum.
INIT_OPEN   sta   RC_OPARM+1
            stx   RC_OPARM+2
            stz   RC_OPARM+3
            stz   RC_OPARM+4
            lda   #RC_PCOPEN
            sta   RC_OPARM
            ldy   #SYS_OPEN
            jsr   INIT_RCSYS
            lda   RC_OPARM+5           ;(LDA leaves carry alone)
            rts

* INIT_CLOSE -- close the fd already in RC_OPARM+1.
INIT_CLOSE  lda   #RC_PCCLOSE
            sta   RC_OPARM
            ldy   #SYS_CLOSE

* INIT_RCSYS -- call Y with the RC_OPARM parmlist.
INIT_RCSYS  lda   #<RC_OPARM
            ldx   #>RC_OPARM
            jmp   $FF00

PAR_PROC_LEN equ *-PARENT_PROC

*---------------------------------------------------------------
* VC_SUITE -- the per-console state roundtrip (S3, 2026-08-23).
* Proves the VC struct save/load machinery moves the WHOLE
* struct, exactly, both directions -- the property that decays
* silently if a 24th per-console field is ever added outside
* the block or VC_ST_SIZE stops covering it. Runs before the
* scheduler starts (interrupts still masked), so nothing else
* can touch the struct mid-measurement.
*
* Steps (R_VC_STEP; a $99 verdict parks the failing step in
* R_VC_ERR):
*  0 plant sentinels in vc0's live struct, checksum -> R_VC_CKA
*  1 VC_SWITCH 1: a first-touch console must arrive RESET
*  2 fill vc1's struct with $A5 (cursor marked hidden after --
*    VC_SWITCH parks the cursor via the struct, and $A5 in
*    VC_CRSR_VIS/ROW/COL would paint a glyph at a garbage
*    address on the way out)
*  3 VC_SWITCH 0: vc0's checksum and sentinels must be EXACT
*  4 VC_SWITCH 1: the $A5 pattern must have been SAVED --
*    proves the annex slot really holds state, not defaults
*  5 home to vc0, VC_RESET to leave a sane console for boot
*---------------------------------------------------------------
*---------------------------------------------------------------
* VCS_PUTMARK / VCS_GETMARK -- plant and test one distinctive
* cell on the 40-column glass, well inside the terminal body.
* GETMARK returns Z SET when the marker is present.
*
* Row 5, column 0: arbitrary, well inside the body -- the store
* carries all 24 rows now (2026-09-03 row-0 reclaim), so this no
* longer has to dodge a reserved row 0.
*---------------------------------------------------------------
VCS_MARKROW equ 5
VCS_MARKVAL equ $D6              ;'V' as a display code

VCS_PUTMARK
            lda   #VCS_MARKROW
            jsr   TTY_ROW_DST_A
            ldy   #0
            lda   #VCS_MARKVAL
            sta   (P_PTR2),y
            rts

VCS_GETMARK
            lda   #VCS_MARKROW
            jsr   TTY_ROW_DST_A
            ldy   #0
            lda   (P_PTR2),y
            cmp   #VCS_MARKVAL
            rts

VC_SUITE
            stz   R_VC_STEP
            lda   #7
            sta   VC_ROW
            lda   #13
            sta   VC_COL
            lda   #1
            sta   VC_ATTR
            lda   #2
            sta   VC_ESC_STATE
            lda   #'Q'
            sta   VC_INBUF
            lda   #'Z'
            sta   VC_INBUF+127
            lda   #'R'
            sta   VC_RAW_BUF+63
            lda   #'Y'
            sta   VC_OUTSHDW+79
            lda   #80
            sta   VC_OSHDW_LEN
            ;-- VC_CRSR_VIS is NOT a byte VC_SWITCH ever
            ;-- round-trips: TTY_CRSR_HIDE unconditionally
            ;-- zeroes it on the OUTGOING console before
            ;-- VC_SAVE_X captures the struct (tty3.s
            ;-- VC_SWITCH / tty4.s TTY_CRSR_HIDE) -- an
            ;-- inactive console's saved image never shows a
            ;-- cursor, by design. Pin it to 0 here, the same
            ;-- way step 2 already pins vc1's copy, so this
            ;-- baseline checksum only covers bytes a real
            ;-- switch actually preserves (2026-09-27: TTY_TICK
            ;-- can show the cursor here before this baseline
            ;-- if a VBL tick lands inside one of KSEG_BOOT's
            ;-- own PMLI_*_CALL islands during boot -- a real,
            ;-- if occasional, timing race against this exact
            ;-- moment, not a struct/save defect).
            stz   VC_CRSR_VIS
            jsr   VC_CKSUM
            lda   R_VC_CK
            sta   R_VC_CKA
            lda   R_VC_CK+1
            sta   R_VC_CKA+1

            ;-- THE SCREEN, not just the struct. Plant a marker
            ;-- on vc0's glass; it must be GONE on vc1 (a first
            ;-- touch arrives blank) and BACK on vc0 (restored
            ;-- from the console store, docs/CONSOLE.md sec 13).
            ;-- The second is the one with teeth: with no store
            ;-- the glass simply stays blank on the way back.
            jsr   VCS_PUTMARK

            lda   #1
            sta   R_VC_STEP
            lda   #1
            jsr   VC_SWITCH
            jsr   VCS_GETMARK        ;must be GONE on vc1
            beq   :f1
            lda   VC_ACTIVE
            cmp   #1
            bne   :f1
            lda   VC_ROW                   ;VC_RESET homes to
            bne   :f1                      ;row 0 now
            lda   VC_COL
            bne   :f1
            lda   VC_ESC_STATE
            bne   :f1
            lda   VC_ATTR
            bne   :f1
            bra   :step2
:f1         jmp   :fail
:step2

            lda   #2
            sta   R_VC_STEP
            lda   #$A5
            ldx   #0
:fill1      sta   VC_STATE,x
            inx
            bne   :fill1
            ldx   #0
:fill2      sta   VC_STATE+256,x
            inx
            cpx   #VC_ST_SIZE-256
            bne   :fill2
            stz   VC_CRSR_VIS              ;see header -- keep
                                           ;the cursor parked
                                           ;while ROW/COL are
                                           ;pattern bytes

            lda   #3
            sta   R_VC_STEP
            lda   #0
            jsr   VC_SWITCH
            jsr   VCS_GETMARK        ;THE TEETH: restored glass
            bne   :f3
            jsr   VC_CKSUM
            lda   R_VC_CK
            cmp   R_VC_CKA
            bne   :f3
            lda   R_VC_CK+1
            cmp   R_VC_CKA+1
            bne   :f3
            lda   VC_ROW
            cmp   #7
            bne   :f3
            lda   VC_INBUF+127
            cmp   #'Z'
            bne   :f3
            bra   :step4
:f3         jmp   :fail
:step4

            lda   #4
            sta   R_VC_STEP
            lda   #1
            jsr   VC_SWITCH
            lda   VC_STATE
            cmp   #$A5
            bne   :fail
            lda   VC_STATE+17
            cmp   #$A5
            bne   :fail
            lda   VC_STATE+256
            cmp   #$A5
            bne   :fail
            lda   VC_STATE+VC_ST_SIZE-1
            cmp   #$A5
            bne   :fail

            lda   #5
            sta   R_VC_STEP
            stz   VC_CRSR_VIS
            lda   #0
            jsr   VC_SWITCH
            jsr   VC_RESET
            lda   #$66
            sta   R_VC_DONE
            rts
:fail       lda   R_VC_STEP
            sta   R_VC_ERR
            stz   VC_CRSR_VIS
            lda   #0
            jsr   VC_SWITCH
            jsr   VC_RESET
            lda   #$99
            sta   R_VC_DONE
            rts

* VC_CKSUM -- 16-bit additive checksum of the active VC struct
* (290 bytes: one 256-byte indexed pass plus the 34-byte tail).
VC_CKSUM
            lda   #0
            sta   R_VC_CK
            sta   R_VC_CK+1
            ldx   #0
:pass1      lda   VC_STATE,x
            clc
            adc   R_VC_CK
            sta   R_VC_CK
            lda   R_VC_CK+1
            adc   #0
            sta   R_VC_CK+1
            inx
            bne   :pass1
            ldx   #0
:pass2      lda   VC_STATE+256,x
            clc
            adc   R_VC_CK
            sta   R_VC_CK
            lda   R_VC_CK+1
            adc   #0
            sta   R_VC_CK+1
            inx
            cpx   #VC_ST_SIZE-256
            bne   :pass2
            rts
