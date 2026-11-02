*---------------------------------------------------------------
* bankcopytestb.s -- image body for bankcopytest.s.
* Split out so the top-level stays a thin MANIFEST: real
* Merlin holds the resident top-level source AND the PUT
* file being read in the same 41215-byte buffer, so every
* byte here would come off every module's budget.
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J)
*---------------------------------------------------------------


*---------------------------------------------------------------
* MAIN_ENTRY -- installs the page-1-resident copyin/copyout
* core, applies the combo selector Python poked into TEST_COMBO,
* runs THREE bank<->bank BankCopy calls (one per video hole,
* plus one crossing INTO hires page 2 -- see COPY3_ADDR), then
* halts with DONE_MARKER=$AA for scripts/check_bankcopy.py to
* poll.
*---------------------------------------------------------------
*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
SRC_BANK    equ   3
DST_BANK    equ   4

MAIN_ENTRY
            jsr   INSTALL_COPY

            ;-- apply the incoming-state combo: bit0=80STORE,
            ;bit1=
            ;-- PAGE2, bit2=HIRES (0=off, 1=on). TEST_COMBO is
            ;poked by
            ;-- Python AFTER reset+mount_disk but BEFORE step --
            ;ordinary
            ;-- main RAM, poke-able (unlike the switches
            ;themselves). --
            lda   TEST_COMBO
            and   #1
            beq   :store_off
            sta   SET80STORE
            bra   :page2
:store_off  sta   CLR80STORE
:page2      lda   TEST_COMBO
            and   #2
            beq   :page2_off
            sta   PAGE2ON
            bra   :hires
:page2_off  sta   PAGE2OFF
:hires      lda   TEST_COMBO
            and   #4
            beq   :hires_off
            sta   HIRESON
            bra   :gocopy
:hires_off  sta   HIRESOFF
:gocopy

            ;-- READY/GO handshake (found necessary by testing):
            ;the
            ;-- //e ROM's own reset/boot sequence writes to low
            ;memory
            ;-- (incl. $0300-$07FF, the text page) BEFORE this
            ;harness's
            ;-- block-0 loader even gets control -- Python
            ;cannot poke
            ;-- the "before" sentinel patterns until AFTER that
            ;firmware
            ;-- churn is done, or the firmware's own writes show
            ;up as
            ;-- spurious "main memory corrupted" findings
            ;indistinguishable
            ;-- from a real BankCopy bug (this harness's first
            ;version hit
            ;-- exactly that false positive on EVERY combo,
            ;including
            ;-- 80STORE=0, which cannot be the 80STORE
            ;misroute). Signal
            ;-- READY here (everything upstream -- ROM boot,
            ;SmartPort
            ;-- load, combo switch setup -- is done); Python
            ;then pokes
            ;-- the sentinel/pattern data and sets GO; only then
            ;do the
            ;-- three BankCopy calls run. --
            lda   #$55
            sta   READY_MARKER
:waitgo     lda   GO_FLAG
            cmp   #$5A
            bne   :waitgo

            ;-- THREE bank<->bank BankCopy calls, SRC_BANK ->
            ;DST_BANK,
            ;-- one range per video hole (plus the hires-page-2
            ;-- crossing, third call below) -- NOT one
            ;$0300-$21FF range,
            ;-- because this harness's OWN loaded code occupies
            ;-- $0800-$17FF (NBLOCKS*512 bytes, DMA'd there by
            ;the
            ;-- LOADER above regardless of this file's actual
            ;code
            ;-- size -- the padding `ds` at EOF guarantees the
            ;SmartPort
            ;-- read always fills the whole span) and a single
            ;range
            ;-- spanning both holes would run straight through
            ;it,
            ;-- making "did main memory get corrupted" ambiguous
            ;between
            ;-- "BankCopy has the 80STORE bug" and "the loader
            ;legitimately
            ;-- loaded code there" (found by testing: the first
            ;version of
            ;-- this harness used one $0300-$21FF range and
            ;FAILED all 8
            ;-- combos on exactly that ambiguity -- 5060 bytes
            ;of "main
            ;-- memory corruption" that were actually just the
            ;loader's
            ;-- own DMA, not a BankCopy bug). COPY1_ADDR ends
            ;exactly at
            ;-- $0800 (never touches the loaded region);
            ;COPY2_ADDR starts
            ;-- at $1F00, safely above where the loader's DMA
            ;ends
            ;-- ($1800 = $0800+8*512). Each range still
            ;individually
            ;-- CROSSES its video hole (starts before/at the
            ;boundary,
            ;-- covers the whole hole). --
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #SRC_BANK
            sta   K_BC_SRCBANK
            lda   #<COPY1_ADDR
            sta   K_BC_SRCADDR
            lda   #>COPY1_ADDR
            sta   K_BC_SRCADDR+1

            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #DST_BANK
            sta   K_BC_DSTBANK
            lda   #<COPY1_ADDR
            sta   K_BC_DSTADDR
            lda   #>COPY1_ADDR
            sta   K_BC_DSTADDR+1

            lda   #<COPY1_LEN
            sta   K_BC_LEN
            lda   #>COPY1_LEN
            sta   K_BC_LEN+1

            jsr   BankCopy

            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #SRC_BANK
            sta   K_BC_SRCBANK
            lda   #<COPY2_ADDR
            sta   K_BC_SRCADDR
            lda   #>COPY2_ADDR
            sta   K_BC_SRCADDR+1

            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #DST_BANK
            sta   K_BC_DSTBANK
            lda   #<COPY2_ADDR
            sta   K_BC_DSTADDR
            lda   #>COPY2_ADDR
            sta   K_BC_DSTADDR+1

            lda   #<COPY2_LEN
            sta   K_BC_LEN
            lda   #>COPY2_LEN
            sta   K_BC_LEN+1

            jsr   BankCopy

            ;-- third range: crosses OUT of the 80STORE+HIRES
            ;-- override window ($2000-$3FFF) INTO hires page 2
            ;-- ($4000-$5FFF) -- task #4's console/video
            ;-- amendment. The $3FFF/$4000 boundary is where the
            ;-- redirection STOPS (hires page 2 is never
            ;-- 80STORE-routed; only $0400-$07FF and, with
            ;-- HIRES, $2000-$3FFF are --
            ;-- learning:01KW1GTYHGXMBZNR6DMQB2F712). On today's
            ;-- unconditional whole-call bracket this range's
            ;-- red condition is a strict SUBSET of COPY2's; it
            ;-- exercises the amendment's named range and pins
            ;-- the boundary in case bracketing ever becomes
            ;-- address-conditional (see check_bankcopy.py's
            ;-- CALIBRATION note). --
            lda   #BC_KIND_BANK
            sta   K_BC_SRCKIND
            lda   #SRC_BANK
            sta   K_BC_SRCBANK
            lda   #<COPY3_ADDR
            sta   K_BC_SRCADDR
            lda   #>COPY3_ADDR
            sta   K_BC_SRCADDR+1

            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   #DST_BANK
            sta   K_BC_DSTBANK
            lda   #<COPY3_ADDR
            sta   K_BC_DSTADDR
            lda   #>COPY3_ADDR
            sta   K_BC_DSTADDR+1

            lda   #<COPY3_LEN
            sta   K_BC_LEN
            lda   #>COPY3_LEN
            sta   K_BC_LEN+1

            jsr   BankCopy

            lda   #$AA
            sta   DONE_MARKER
:hang       jmp   :hang

*-- SRC_BANK: hoisted above its first use (EQU burn-down).
*-- DST_BANK: hoisted above its first use (EQU burn-down).
COPY1_ADDR  equ   $0300
COPY1_LEN   equ   $0500        ;$0300-$07FF: crosses/covers
                               ;$0400-$07FF, stops exactly at
                               ;$0800 (the loader's own region
                               ;-- never entered)
COPY2_ADDR  equ   $1F00
COPY2_LEN   equ   $0500        ;$1F00-$23FF: crosses into
                               ;$2000-$3FFF, starts safely above
                               ;$1800 (where the loader's DMA
                               ;ends)
COPY3_ADDR  equ   $3F00
COPY3_LEN   equ   $0500        ;$3F00-$43FF: crosses OUT of the
                               ;$2000-$3FFF override window INTO
                               ;hires page 2 ($4000-$5FFF) --
                               ;straddles the $3FFF/$4000
                               ;boundary where 80STORE+HIRES
                               ;redirection stops

;-- FIXED addresses (not code-stream `ds`), so
;scripts/check_bankcopy.py
;-- can poke/peek them without parsing a symbol table -- same
;$9xxx
;-- module-local-scratch convention src/kernel/bankprobe.s
;documents
;-- (preferred non-video K_CODE_C span, clear of COPY_ADDR's
;$0300-$21FF
;-- range and bankprobe.s's own $9000-$9180 in case both ever
;share an image). --
TEST_COMBO   equ   $9300           ;poked by Python before step:
                                   ;bits 0/1/2 = incoming
                                   ;80STORE/PAGE2/HIRES
READY_MARKER equ   $9301            ;$55 once ROM boot + combo
                                    ;setup is done -- Python's
                                    ;cue to poke data
GO_FLAG      equ   $9302             ;Python sets $5A once data
                                     ;is poked
DONE_MARKER  equ   $9303              ;$AA once BankCopy has
                                      ;returned

            ds    $0800+4096-*                  ;pad to 8 blocks
                                                ;(NBLOCKS)
