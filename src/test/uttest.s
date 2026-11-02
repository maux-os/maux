*---------------------------------------------------------------
* uttest.s -- acceptance gate for the UltraTerm backend (`make
* check-ultraterm`).
*
* Exercises src/kernel/ultraterm.s against a real card and lets
* verilogapple's `ultraterm_state` assert the result. That tool
* exists because the card is write-only over the bus: nothing --
* not guest code, not a debug peek -- can read a character back
* (docs/CONSOLE.md section 10a). So this image cannot
* self-check; it drives the card and scripts/check_ultraterm.py
* reads the verdict off the card itself.
*
* THE SEQUENCE IS CHOSEN TO CROSS THE 4 KB RING WRAP, which is
* the one thing in this backend that fails silently. 50 scrolls
* put the display start at 4000; rows 2 and below then wrap past
* $0FFF. A driver that masked wrongly still looks perfect for
* the first ~51 scrolls, so a test that scrolls three times
* proves almost nothing.
*
* 1. detect + init -> $0310 = 1 if found 2. scroll 50x ->
* display start = 4000 3. label rows 0-23 "Rnn" -> every row now
* wraps 4. inverse '*' at row 2 col 10 -> bit7 attribute 5.
* STATUS across row 0, scroll once -> it is GONE, shift by 1 6.
* cursor to row 5 col 10 -> hardware cursor
*---------------------------------------------------------------

* A ProDOS SYSTEM file, not a boot block: with the row-offset
* tables the module is well over the
* 512-byte block-0 ceiling that build_image.py enforces, and
* shrinking a DRIVER to fit its own test harness is the wrong
* trade. Hosted-mode boot is sanctioned by
* learning:01KYYGZ8C3FQFWCF3S0FQ0DJ7B.

            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $2000
            dsk   ../../build/MAUXUT.SYSTEM
            typ   $FF
KBSS        equ   $0A00        ;kernel scratch home
            put   ../../inc/mm.kbss.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/ultraterm.equ

START       sei
            ldx   #$FF
            txs
            cld
            ;-- Hop the label strings -- moved up here so their
            ;-- *_LEN equates are defined before their immediate
            ;-- uses (S9 EQU burn-down 2026-08-29; real Merlin-8
            ;-- refuses the forward reference).
            bra   UTT_EQHOP
STATUS      asc   "STATUS"
STATLEN     equ   *-STATUS
UTT_EQHOP
            ;-- Unmask. Nothing in this image handles an IRQ, so
            ;-- check_ultraterm.py boots it with the mouse and
            ;-- clock cards OFF and there is no source. What it
            ;-- buys is that I=0 is the CALLER's state, making
            ;-- UT_CLAIM's own sei/plp bracket observable: the
            ;-- gate asserts I=1 at the SETSLOTC3ROM write and
            ;-- I=0 again after the restore. With the sei above
            ;-- left standing, removing UT_CLAIM's bracket would
            ;-- look identical from outside.
            cli

            ;-- 1. Detect. The result goes to main RAM where a
            ;-- plain peek can see it -- if no card answered,
            ;-- every later assertion would fail for a reason
            ;the
            ;-- card state cannot explain.
            jsr   UT_DETECT
            lda   UT_PRESENT
            sta   $0310
            bne   :haveut
            jmp   SPIN                      ;no card: leave
                                            ;$0310=0 and stop
:haveut
            jsr   UT_INIT

            ;-- 2. Fifty scrolls. Start ends at 50*80 = 4000
            ;-- ($0FA0), so rows 2-23 address past the end of
            ;-- VRAM and must wrap.
            ldx   #50
:scrolllp   phx
            ldx   #1                        ;one row
            jsr   UT_SCROLL
            plx
            dex
            bne   :scrolllp

            ;-- 3. Label every row "Rnn" in columns 0-2.
            ldx   #0
:rowlp      phx
            lda   #'R'
            ldy   #0
            jsr   UT_PUT_CELL               ;A=char X=row Y=col
            plx
            phx
            txa
            jsr   DIV10                     ;A -> tens in A,
                                            ;units in UNITS
            clc
            adc   #'0'
            ldy   #1
            plx
            phx
            jsr   UT_PUT_CELL
            lda   UNITS
            clc
            adc   #'0'
            ldy   #2
            plx
            phx
            jsr   UT_PUT_CELL
            plx
            inx
            cpx   #UT_ROWS
            bne   :rowlp

            ;-- 4. Inverse '*' at row 2, column 10. Bit 7 is the
            ;-- card's inverse-video ATTRIBUTE, not a font
            ;-- address line, so the glyph stays '*'.
            lda   #'*'+$80
            ldx   #2
            ldy   #10
            jsr   UT_PUT_CELL

            ;-- 5. Write STATUS across row 0, then scroll once.
            ;-- Row 0 is ordinary content (no reserved status
            ;-- line, 2026-09-03): the scroll must carry it OFF
            ;-- the top, not re-stamp it -- the gate asserts the
            ;-- word is gone; row 0 shows the old row 1.
            ldy   #0
:stamplp    sty   UNITS                     ;column, kept across
            lda   STATUS,y                  ;the cell write
            ldx   #0                        ;row 0
            jsr   UT_PUT_CELL
            ldy   UNITS
            iny
            cpy   #STATLEN
            bne   :stamplp
            ldx   #1                        ;one row
            jsr   UT_SCROLL

            ;-- 6. Hardware cursor, last so its address is
            ;-- deterministic.
            ldx   #5
            ldy   #10
            jsr   UT_CRSR_AT

SPIN        jmp   SPIN

*---------------------------------------------------------------
* DIV10 -- A / 10 -> A, remainder -> UNITS. Rows only go to 23,
* so repeated subtraction is fine and a table is not worth it.
*---------------------------------------------------------------
DIV10       ldx   #0
:lp         cmp   #10
            bcc   :done
            sec
            sbc   #10
            inx
            bra   :lp
:done       sta   UNITS
            txa
            rts

UNITS       ds    1


            put   ../kernel/ultraterm.s


            put   ../kernel/ultraterm2.s
