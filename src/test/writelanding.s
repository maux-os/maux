*---------------------------------------------------------------
* writelanding.s -- task #4 deliverable 3, the [likely]-grade
* experiment: with 80STORE+PAGE2 set and a non-zero bank
* selected via $C073, where do CPU writes to $0400-$07FF land --
* bank 0 or the selected bank?
* Full design notes: T.WRITELAND.TXT (docs/a2/)
*---------------------------------------------------------------

*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
WLBANK      equ   5              ;arbitrary non-zero bank
MARKER      equ   $42            ;arbitrary marker byte,

            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/writelanding.bin
            typ   $00

            dfb   $01                        ;chain count (ROM
                                             ;convention)

            put   ../../inc/mm.hw.equ

START       sei
            ldx   #$FF
            txs
            cld

            ;-- select a non-zero bank. $C073 is write-only and
            ;UNKNOWN
            ;-- at every entry (docs/ARCHITECTURE.md) -- always
            ;written,
            ;-- never assumed. --
            lda   #WLBANK
            sta   BANKSEL

            ;-- 80STORE + PAGE2 ON (the exact incoming state the
            ;-- experiment targets). A's value (WLBANK) is
            ;irrelevant to
            ;-- these two triggers -- STA fires on address, not
            ;data. --
            sta   SET80STORE
            sta   PAGE2ON

            ;-- the write under test --
            lda   #MARKER
            sta   $0400

            ;-- signal completion for the script's poll loop,
            ;then halt --
            lda   #$AA
            sta   DONE

:hang       jmp   :hang

*-- WLBANK: hoisted above its first use (EQU burn-down).
*-- MARKER: hoisted above its first use (EQU burn-down).
                                 ;distinct from both banks'
                                 ;reset-state content
;-- FIXED address (not code-stream `ds`), same convention as
;-- bankcopytest.s's TEST_COMBO/DONE_MARKER -- lets
;-- scripts/experiment_writelanding.py peek it without parsing a
;symbol
;-- table. Far from $0800-$0Bxx (this program's own code) and
;from
;-- $0400 (the address under test). --
DONE        equ   $9300

            ds    $0800+512-*                   ;pad to exactly
                                                ;512 bytes
