*---------------------------------------------------------------
* prodos.spike.s -- task #11 acceptance gate (`make check-mli`).
*
* A ProDOS 8 SYS file (MAUX.SYSTEM). Boots as an ordinary ProDOS
* system program (a2til-built volume, vendored ProDOS 2.4 kernel
* -- see scripts/build_mli_image.py), takes over per the A7
* lifecycle (learning:01KW1GTYH4NRG0F8M7AAT6EG9Z), installs the
* spike's minimal kernel skeleton (src/kernel/mli.s -- raw $FFFE
* ownership + MLI lock), then runs the five docs/TASKS.md #11
* experiments in order, leaving results in a fixed set of
* `ds`-placed globals the check script recovers via merlin32
* -v1's own symbol table (same technique as
* scripts/check_sched.py -- these addresses are NOT fixed, they
* shift whenever this file's source size changes).
*
* Deliberately main-context only, no per-process bank machinery:
* this spike answers "can ProDOS's MLI and a maux kernel
* skeleton coexist", not "is the syscall ABI wired to it"
* (that's task #12+, explicitly gated on this file's own answers
* per docs/TASKS.md #11's last line).
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            jmp   ENTRY          ;hop the banner data --
                                  ;moved up here so BANNERLEN
                                  ;is defined before its
                                  ;immediate use (S9 EQU
                                  ;burn-down 2026-08-29)
BANNER      asc   "MAUX MLI SPIKE"
BANNERLEN   equ   *-BANNER


            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.mli.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/ultraterm.equ
            dsk   ../../build/MAUXSPIKE.SYSTEM
            typ   $FF

*===============================================================
* ENTRY -- ProDOS JMPs here (not JSRs -- no return address to
* preserve).
*===============================================================
ENTRY       sei
            cld
            ldx   #$FF
            txs

            ldy   #0                        ;boot banner --
                                            ;proves control
:banner     lda   BANNER,y                  ;reached MAUX.SYSTEM
                                            ;before
            sta   $0400,y                   ;anything else runs
            iny
            cpy   #BANNERLEN
            bne   :banner

            lda   #1
            sta   R_PHASE

* -- (a) ZP AS PRODOS LEFT IT -- before this program touches
* anything. --
            ldy   #0
:snap0      lda   $00,y
            sta   R_ZP_BOOT,y
            iny
            bne   :snap0

* -- A7 lifecycle: record HAD_RAM, disconnect /RAM
* (src/kernel/mli.s). --
            jsr   RAM_DISCON
            lda   #2
            sta   R_PHASE

* -- install the kernel skeleton: direct-PIA mouse bring-up +
* raw $FFFE -- ownership (docs/PRODOS-SPIKE.md answer (b)).
* INSTALL_IRQ also -- snapshots the PRE-PATCH $FF00-$FFFF page
* into MLI_VCPG_BOOT. --
            jsr   MOUSE_INIT
            jsr   INSTALL_IRQ
            lda   #3
            sta   R_PHASE
            cli                              ;ticks start
                                             ;accumulating now

            ldy   #0                         ;ZP snapshot #2 --
                                             ;post-init,
:snap1      lda   $00,y                      ;pre-first-MLI-call
            sta   R_ZP_PREMLI,y
            iny
            bne   :snap1

* -- (a)/probe: GET_TIME, the cheap MLI probe TASKS.md #11 calls
* out. -- Isolated single-call ZP bracket (distinct from the
* boot/pre/post-MLI -- three-point snapshot elsewhere in this
* file, which spans the WHOLE -- 9-call sequence): this one
* tests the TRM's OWN narrow claim -- "the -- MLI uses zero-page
* locations $40-$4E, but it restores them before it -- completes
* a call" -- against a SINGLE bracketed call, since a multi- --
* call diff can't distinguish "restored to its OWN pre-call
* value" from -- "drifted to a new resting value that happens to
* differ call-to-call". --
            ldy   #0
:snapgt0    lda   $00,y
            sta   R_ZP_PREGT,y
            iny
            bne   :snapgt0
            jsr   MLI
            dfb   $82
            da    GETTIME_PARMS
            sta   R_GETTIME_ERR
            ldy   #0
:snapgt1    lda   $00,y
            sta   R_ZP_POSTGT,y
            iny
            bne   :snapgt1

* -- (d): process A's file round trip, lock held for the WHOLE
* sequence. -- MLI_WTR_WANT is set BEFORE A acquires, so
* every VBL tick landing during -- A's critical section is a
* genuine contention observation, not a lucky -- footrace. --
            lda   #5
            sta   R_PHASE
            lda   #1
            sta   MLI_WTR_WANT
            lda   #1                         ;holder id 1 =
                                             ;"process A"
            jsr   MLI_LOCK_ACQ
            lda   #<PATH_TESTA
            sta   FR_PATH
            lda   #>PATH_TESTA
            sta   FR_PATH+1
            lda   #<TESTA_DATA
            sta   FR_DATA
            lda   #>TESTA_DATA
            sta   FR_DATA+1
            lda   #<TESTA_LEN
            sta   FR_LEN
            lda   #>TESTA_LEN
            sta   FR_LEN+1
            jsr   FR_WRITE_FILE
            lda   FR_ERR
            sta   R_A_ERR
            jsr   MLI_LOCK_REL
            lda   #6
            sta   R_PHASE

* -- idle loop: let VBL_ISR's contention-driven dispatch flag
* fire once -- the lock is free; when it does, run process B's
* own sequence under -- its own lock hold. Bounded by
* MLI_WTR_READY so the check script's -- step budget has a
* deterministic exit, not an unbounded spin. --
:waitb      lda   MLI_WTR_READY
            beq   :waitb
            stz   MLI_WTR_READY
            stz   MLI_WTR_WANT
            lda   #2                         ;holder id 2 =
                                             ;"process B"
            jsr   MLI_LOCK_ACQ
            lda   #<PATH_TESTB
            sta   FR_PATH
            lda   #>PATH_TESTB
            sta   FR_PATH+1
            lda   #<TESTB_DATA
            sta   FR_DATA
            lda   #>TESTB_DATA
            sta   FR_DATA+1
            lda   #<TESTB_LEN
            sta   FR_LEN
            lda   #>TESTB_LEN
            sta   FR_LEN+1
            jsr   FR_WRITE_FILE
            lda   FR_ERR
            sta   R_B_ERR
            jsr   MLI_LOCK_REL
            lda   #7
            sta   R_PHASE

* -- (b)/(c): the long file -- CREATE+OPEN+WRITE(2KB, one
* call)+CLOSE, then -- OPEN+READ(2KB, one call)+CLOSE.
* WRITE_CALL_PC/WRITE_RET_PC and -- READ_CALL_PC/READ_RET_PC
* bracket the two big transfers for the check -- script's
* until_pc/step_inst work. --
            jsr   LONG_WRITE
            lda   #8
            sta   R_PHASE
            jsr   LONG_READ
            lda   #9
            sta   R_PHASE

            ldy   #0                         ;ZP snapshot #3 --
                                             ;final
:snap2      lda   $00,y
            sta   R_ZP_POSTMLI,y
            iny
            bne   :snap2

            lda   #99
            sta   R_PHASE                    ;99 = every phase
                                             ;completed
:park       bra   :park

GETTIME_PARMS
            dfb   0

*===============================================================
* FR_WRITE_FILE -- CREATE, OPEN, WRITE, CLOSE. Caller sets
* FR_PATH (pathname pointer), FR_DATA (source buffer pointer),
* FR_LEN (byte count) first. Leaves the last MLI error in FR_ERR
* (0 = every step succeeded).
*===============================================================
FR_WRITE_FILE
            lda   FR_PATH
            sta   CREATE_PARMS+1
            lda   FR_PATH+1
            sta   CREATE_PARMS+2
            jsr   MLI
            dfb   $C0
            da    CREATE_PARMS
            sta   FR_ERR
            bne   SPK_WDONE

            lda   FR_PATH
            sta   OPEN_PARMS+1
            lda   FR_PATH+1
            sta   OPEN_PARMS+2
            jsr   MLI
            dfb   $C8
            da    OPEN_PARMS
            sta   FR_ERR
            bne   SPK_WDONE
            lda   OPEN_PARMS+5
            sta   FR_REFNUM
            sta   WRITE_PARMS+1
            sta   CLOSE_PARMS+1

            lda   FR_DATA
            sta   WRITE_PARMS+2
            lda   FR_DATA+1
            sta   WRITE_PARMS+3
            lda   FR_LEN
            sta   WRITE_PARMS+4
            lda   FR_LEN+1
            sta   WRITE_PARMS+5
WRITE_CALL_PC
            jsr   MLI
            dfb   $CB
            da    WRITE_PARMS
WRITE_RET_PC
            sta   FR_ERR

:wdoclose   jsr   MLI
            dfb   $CC
            da    CLOSE_PARMS
SPK_WDONE      rts

*===============================================================
* FR_READ_FILE -- OPEN (existing file), READ, CLOSE. Caller sets
* FR_PATH, FR_DATA (destination buffer), FR_LEN (request_count)
* first. Leaves FR_TRANS (trans_count) and FR_ERR.
*===============================================================
FR_READ_FILE
            lda   FR_PATH
            sta   OPEN_PARMS+1
            lda   FR_PATH+1
            sta   OPEN_PARMS+2
            jsr   MLI
            dfb   $C8
            da    OPEN_PARMS
            sta   FR_ERR
            bne   SPK_RDONE
            lda   OPEN_PARMS+5
            sta   FR_REFNUM
            sta   READ_PARMS+1
            sta   CLOSE_PARMS+1

            lda   FR_DATA
            sta   READ_PARMS+2
            lda   FR_DATA+1
            sta   READ_PARMS+3
            lda   FR_LEN
            sta   READ_PARMS+4
            lda   FR_LEN+1
            sta   READ_PARMS+5
READ_CALL_PC
            jsr   MLI
            dfb   $CA
            da    READ_PARMS
READ_RET_PC
            sta   FR_ERR
            lda   READ_PARMS+6
            sta   FR_TRANS
            lda   READ_PARMS+7
            sta   FR_TRANS+1

:rdoclose   jsr   MLI
            dfb   $CC
            da    CLOSE_PARMS
SPK_RDONE      rts

*===============================================================
* LONG_WRITE / LONG_READ -- the "survive a long MLI call" test
* (b)/(c). WRITE_SRC_BUF is filled with a repeating 0-255 ramp
* so LONG_READ's result can be verified byte-for-byte by the
* check script (via a2til, post-run, reading the finished disk
* image directly -- simpler and more convincing than trying to
* peek 2KB back out of emulator memory).
*===============================================================
LONG_WRITE  ldx   #0
:fill0      txa
            sta   WRITE_SRC_BUF,x
            sta   WRITE_SRC_BUF+256,x
            sta   WRITE_SRC_BUF+512,x
            sta   WRITE_SRC_BUF+768,x
            sta   WRITE_SRC_BUF+1024,x
            sta   WRITE_SRC_BUF+1280,x
            sta   WRITE_SRC_BUF+1536,x
            sta   WRITE_SRC_BUF+1792,x
            inx
            bne   :fill0
            lda   #<PATH_LONG
            sta   FR_PATH
            lda   #>PATH_LONG
            sta   FR_PATH+1
            lda   #<WRITE_SRC_BUF
            sta   FR_DATA
            lda   #>WRITE_SRC_BUF
            sta   FR_DATA+1
            lda   #<LONGLEN
            sta   FR_LEN
            lda   #>LONGLEN
            sta   FR_LEN+1
            jsr   FR_WRITE_FILE
            lda   FR_ERR
            sta   R_LNGWRT_ERR
            rts

LONG_READ   lda   #<PATH_LONG
            sta   FR_PATH
            lda   #>PATH_LONG
            sta   FR_PATH+1
            lda   #<READ_DST_BUF
            sta   FR_DATA
            lda   #>READ_DST_BUF
            sta   FR_DATA+1
            lda   #<LONGLEN
            sta   FR_LEN
            lda   #>LONGLEN
            sta   FR_LEN+1
            jsr   FR_READ_FILE
            lda   FR_ERR
            sta   R_LNGRD_ERR
            lda   FR_TRANS
            sta   R_LNGRD_TRANS
            lda   FR_TRANS+1
            sta   R_LNGRD_TRANS+1
            rts

*===============================================================
* Fixed pathname strings -- LOW-BIT ASCII (single-quoted `asc`,
* confirmed against the merlin32 dialect empirically: `asc "X"`
* sets the high bit, `asc 'X'` does not -- see docs/PRODOS-
* SPIKE.md's deposit-candidate note. The ProDOS 8 TRM's own
* CREATE example listing (line ~1587 of the extracted text, "2F
* 54 45 53 -- NAME ASC /TESTMLI/NEWFILE") confirms pathname
* bytes are plain low-bit ASCII, matching this choice.
*===============================================================
* Volume name is BASIC -- this test's carrier volume (scripts/
* build_mli_image.py starts from a known-good SmartPort-bootable
* ProDOS volume and swaps in the genuine ProDOS 2.4 kernel
* bytes; see that script's own header for why a plain floppy-
* mastered ProDOS_2_4.dsk doesn't autoboot under verilogapple's
* mount_disk).
PATH_TESTA  dfb   11
            asc   '/MAUX/TESTA'
PATH_TESTB  dfb   11
            asc   '/MAUX/TESTB'
PATH_LONG   dfb   14
            asc   '/MAUX/LONGFILE'

*===============================================================
* MLI parameter blocks -- verbatim TRM shapes (docs/SYSCALL.md's
* own table, independently re-confirmed against the TRM during
* this task). Reused across call sites via
* FR_PATH/FR_DATA/FR_LEN self-modifying the pointer/ count
* fields before each JSR -- no zero page anywhere in this file
* (TN #22: never put parameter blocks on zero page; this file
* goes further and keeps the POINTED-TO buffers off zero page
* too, matching maux's existing 0-ZP-usage kernel discipline,
* see docs/PRODOS-SPIKE.md answer (a)).
*===============================================================
CREATE_PARMS
            dfb   7
            da    0                          ;+1,+2 pathname
                                             ;(patched)
            dfb   $C3                        ;access
            dfb   $06                        ;file_type = BIN
            da    $0000                      ;aux_type
            dfb   $01                        ;storage_type =
                                             ;standard file
            da    $0000                      ;create_date
            da    $0000                      ;create_time

OPEN_PARMS  dfb   3
            da    0                          ;+1,+2 pathname
                                             ;(patched)
            da    IOBUF                      ;+3,+4 io_buffer
                                             ;(page-aligned)
            dfb   0                          ;+5 refnum result

WRITE_PARMS dfb   4
            dfb   0                          ;+1 refnum
                                             ;(patched)
            da    0                          ;+2,+3 data_buffer
                                             ;(patched)
            da    0                          ;+4,+5
                                             ;request_count
                                             ;(patched)
            da    0                          ;+6,+7 trans_count
                                             ;result

READ_PARMS  dfb   4
            dfb   0                          ;+1 refnum
                                             ;(patched)
            da    0                          ;+2,+3 data_buffer
                                             ;(patched)
            da    0                          ;+4,+5
                                             ;request_count
                                             ;(patched)
            da    0                          ;+6,+7 trans_count
                                             ;result

CLOSE_PARMS dfb   1
            dfb   0                          ;+1 refnum
                                             ;(patched)

*===============================================================
* Working state (FR_* -- generic file-roundtrip scratch, R_* --
* results the check script peeks). All addresses recovered from
* merlin32 -v1's symbol dump, never hardcoded -- see
* scripts/check_mli.py.
*===============================================================
FR_PATH     ds    2
FR_DATA     ds    2
FR_LEN      ds    2
FR_REFNUM   ds    1
FR_ERR      ds    1
FR_TRANS    ds    2

R_PHASE     ds    1
R_GETTIME_ERR ds  1
R_A_ERR     ds    1
R_B_ERR     ds    1
R_LNGWRT_ERR ds 1
R_LNGRD_ERR  ds 1
R_LNGRD_TRANS ds 2
R_ZP_BOOT   ds    256
R_ZP_PREMLI ds    256
R_ZP_POSTMLI ds   256
R_ZP_PREGT ds 256
R_ZP_POSTGT ds 256

*===============================================================
* Small per-file source/dest buffers (TESTA/TESTB -- the (d)
* lock test). No alignment requirement (only OPEN's io_buffer
* needs page alignment).
*===============================================================
TESTA_DATA  asc   'MAUX PRODOS SPIKE -- FILE A -- PROCESS A OWN'
            asc   'S THIS WRITE'
TESTA_LEN   equ   *-TESTA_DATA
TESTB_DATA  asc   'MAUX PRODOS SPIKE -- FILE B -- PROCESS B OWN'
            asc   'S THIS WRITE'
TESTB_LEN   equ   *-TESTB_DATA

*===============================================================
* mli.s -- kernel-skeleton primitives (RAM_DISCON,
* INSTALL_IRQ, MOUSE_INIT, OUR_IRQ_HNDLR, VBL_ISR,
* K_MLI_LOCK/MLI_LOCK_*).
*===============================================================
            put   ../kernel/mouse.s
            put   ../kernel/mli.s

*===============================================================
* Large buffers, fixed round addresses (page-aligned IOBUF; both
* big buffers get a full 2KB of clearance from the nearest other
* used byte, per the WRITE/READ call's own "limited to the
* number of bytes between data_buffer and the nearest used page"
* constraint).
*===============================================================
            ds    $4000-*
WRITE_SRC_BUF ds  2048                       ;$4000-$47FF (8 x
                                             ;256B fill loop)
LONGLEN     equ   2048

            ds    $6000-*
IOBUF       ds    1024                       ;$6000-$63FF, page-
                                             ;aligned

READ_DST_BUF ds   2048                       ;$6400-$6BFF -- 2KB
                                             ;of clearance
                                             ;before the next
                                             ;used byte (nothing
                                             ;else is allocated
                                             ;past this point)
