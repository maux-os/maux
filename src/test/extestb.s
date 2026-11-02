*---------------------------------------------------------------
* extestb.s -- image body for extest.s. Split out so the top-
* level stays a thin MANIFEST (edtestb.s's own precedent --
* real Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer).
*
* ONE session: `r /mnt/MAUX/EXSRC` (load 5 lines through the
* swap
* file), `,p` (print all 5 -- every one of them read back
* through
* ED_LINETEXT's SET_MARK+READ path), `2s/BANK/SWAPD/` (rewrite
* line 2 -- ED_BUMP_ALLOC appends to the swap file, ED_SETSLOT
* repoints the descriptor), `,p` again (proves the substituted
* line reads back correctly AND that lines 1/3/4/5 still read
* correctly from their ORIGINAL, now out-of-order, swap offsets
* -- no offset-tracking cache is implemented, so this also
* exercises a real SET_MARK on every single line), `w
* /mnt/MAUX/EXOUT` (write all 5 back out, fetching each through
* the
* swap again), `q` (quit -- unlinks the swap file). Both `,p`
* outputs land in one captured stdout file (EXCAP, read back as
* one block); EXOUT is read back separately. check_ex.py
* compares
* both, byte-exact including CR ($8D) line endings, against
* content hand-derived from the script above.
*---------------------------------------------------------------

* -- Result addresses in the parent process bank (bank 1), same
* -- "$1200-$1FFF is free scratch" convention as edtestb.s. --
R_LEN1      equ   $1200      ;byte count captured from EXCAP
                             ;(both `,p` outputs, concatenated)
R_STAGE1    equ   $1210      ;up to 200 bytes -- ends $12D7

R_LENOUT    equ   $12E0      ;byte count captured from EXOUT
R_STAGEOUT  equ   $12F0      ;up to 200 bytes -- ends $13B7

R_SPAWN_PID  equ  $13C0
R_SPAWN_STAT equ  $13C1
R_WAIT_PID   equ  $13C2

R_DONE      equ   $13D0
R_ERR       equ   $13D1
R_STEP      equ   $13D2

* -- second session (Task 0's `j` fix), $1400-$14FF. --
R_LEN2      equ   $1400      ;byte count captured from EXCAP2
                             ;(both `,p` outputs, concatenated)
R_STAGE2    equ   $1410      ;up to 200 bytes -- ends $14D7

R_LENOUT2   equ   $14E0
R_STAGEOUT2 equ   $14F0      ;up to 200 bytes -- ends $15B7

R_SPAWN_PID2  equ $15C0
R_SPAWN_STAT2 equ $15C1
R_WAIT_PID2   equ $15C2

* -- third session (M2 items 2/4/5: marks incl. shift/invalidate
* -- on insert+delete, undo round-trip, #-print, n reserved) --
* -- own block, $1600-$17FF.
R_LEN3      equ   $1600      ;byte count captured from EXCAP3
R_STAGE3    equ   $1610      ;up to 200 bytes -- ends $16D7

R_LENOUT3   equ   $16E0
R_STAGEOUT3 equ   $16F0      ;up to 200 bytes -- ends $17B7

R_SPAWN_PID3  equ $17C0
R_SPAWN_STAT3 equ $17C1
R_WAIT_PID3   equ $17C2

* -- fourth session (M2 items 1/3/6: ?re? backward search incl.
* -- wrap-to-no-match, e/e! incl. the dirty-buffer guard, wq) --
* -- own block, $1800-$19FF.
R_LEN4      equ   $1800
R_STAGE4    equ   $1810      ;up to 200 bytes -- ends $18D7

R_LENOUT4   equ   $18E0
R_STAGEOUT4 equ   $18F0      ;up to 200 bytes -- ends $19B7

R_SPAWN_STAT4 equ $19C1

* -- fifth session (2026-09-02, filename-on-launch task): `ex
* -- FILE` loads FILE through the swap file at STARTUP instead
* -- of a bare launch + `r`. 5a positive (a real fixture,
* -- loaded via argv, `,p`/bare `w` prove the load AND the
* -- remembered filename); 5b negative (a path that does NOT
* -- exist -- must stay `?`, no crash, filename not remembered).
* -- own block, $1A00-$1BFF.
R_LEN5      equ   $1A00      ;byte count from EXCAP5 (`,p`
                             ;capture of the launch-loaded file)
R_STAGE5    equ   $1A10      ;up to 48 bytes
R_LENOUT5   equ   $1A50      ;byte count from EXFILE5, RE-READ
                             ;after the bare `w`
R_STAGEOUT5 equ   $1A60      ;up to 32 bytes
R_SPAWN_PID5  equ $1A90
R_SPAWN_STAT5 equ $1A91
R_WAIT_PID5   equ $1A92

R_LEN5N     equ   $1AA0      ;byte count from EXCAP5N (the
                             ;nonexistent-path negative case)
R_STAGE5N   equ   $1AB0      ;up to 16 bytes
R_SPWN_STAT5N equ $1AD1

*---------------------------------------------------------------
* Boot helpers -- identical pattern to
* edtestb.s/fileproctest.s.
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

BANNER      asc   "MAUX EXTEST"
BANNER_END

*---------------------------------------------------------------
* Parent process image -- copied verbatim into bank 1.
*---------------------------------------------------------------
PARENT_PROC
            stz   R_ERR
            stz   R_STEP

* ---- EXSRC (the file `ex` will load) and EXSCR1 (the command
* ---- script fed to `ex` on fd 0) are ON ex.po already: every
* ---- session's fixture/script file is staged at BUILD time by
* ---- scripts/build_ex_image.py (FIXTURES, 2026-09-08) -- they
* ---- used to be written here from text embedded in this image,
* ---- which is what pushed MAUXEXTEST.SYSTEM past PMLI_IBF_BASE
* ---- (check_kernel_images.py's KNOWN_OVERRUN note). SESSION 1
* ---- itself: r (load) -> ,p (print all) -> 2s/BANK/SWAPD/
* ---- (rewrite line 2) -> ,p again -> w (write back) -> q. See
* ---- extestb3.s's own DESC1/RBL1 (2026-09-12: table-driven,
* ---- this file's header has the why) for the descriptor this
* ---- calls, and the fixture-content comment right above it for
* ---- the full trace. ----
            lda   #<DESC1
            ldx   #>DESC1
            jsr   RUN_SESSION

*---------------------------------------------------------------
* SECOND session -- Task 0's `j` (join) fix, M2 2026-09-02. Same
* rig (RUN_SESSION, DESC2/RBL2 in extestb3.s). Proves the join
* now goes through the swap-file accessor contract instead of
* the raw-arena poke that used to corrupt the line: `1,2j`
* (2-line join) then `,p`, then `2,4j` (3-line join over what's
* now a 4-line buffer) then `,p` again -- the SECOND `,p`
* re-reads the FIRST join's result from its real swap
* descriptor, and `w` re-reads it a THIRD time via an
* independent SET_MARK+READ. The pre-fix bug corrupted exactly
* this: ED_SETSLOT would dereference the joined text's own first
* 4 bytes as a bogus {offset,len}, so any read-back after the
* join returned garbage -- see docs/EX-DESIGN.md sec 5.1 and
* exbuf.s's header. EXSRC2/EXSCR2 staged by build_ex_image.py
* (see session 1's own note).
*---------------------------------------------------------------
            lda   #<DESC2
            ldx   #>DESC2
            jsr   RUN_SESSION

