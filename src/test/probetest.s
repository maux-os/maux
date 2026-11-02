*---------------------------------------------------------------
* probetest.s -- boot image for task #5's acceptance gate (`make
* check-probe`).
* Full design notes: T.PROBETEST.TXT (docs/a2/)
*---------------------------------------------------------------

*-- Hoisted above first use (S9 EQU burn-down 2026-08-29).
MAXSHOW     equ   8                          ;cap on how many

            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $0800
            dsk   ../../build/probetest.bin
            typ   $00
            put   ../../inc/mm.hw.equ
            put   ../../inc/mm.annex.equ
            put   ../../inc/mm.annex2.equ
            put   ../../inc/bankcopy.equ
            put   ../../inc/entry.frame.equ
            put   ../../inc/sched.equ
            put   ../../inc/bankprobe.equ
            put   ../../inc/mli.const.equ
            put   ../../inc/ultraterm.equ

            ;-- Byte at $0800: chain count for the boot ROM
            ;(same reasoning
            ;-- as src/bootblock.s: matches ProDOS's own boot
            ;block).
            dfb   $01

            ;-- Entry point. Boot ROM JMPs here ($0801).
START       sei
            ldx   #$FF
            txs
            cld
            ;-- Hop the label strings -- moved up here so their
            ;-- *_LEN equates are defined before their immediate
            ;-- uses (S9 EQU burn-down 2026-08-29; real Merlin-8
            ;-- refuses the forward reference).
            bra   PRB_EQHOP
BANNER      asc   "MAUX BANKPROBE"
BANNERLEN   equ   *-BANNER
FREELBL     asc   "FREE="
FREELBLLEN  equ   *-FREELBL
BANKSSFX    asc   " BANKS"
BANKSSFXLEN equ   *-BANKSSFX
FIRSTLBL    asc   "FIRST:"
FIRSTLBLLEN equ   *-FIRSTLBL
PRB_EQHOP

            jsr   BankProbe                 ;src/kernel/bankprob
                                            ;e.s: probe all 128
                                            ;bank numbers, build
                                            ;the free list,
                                            ;reserve bank 0

            ;-- Row 0: banner, proves the image is alive even
            ;before the
            ;-- probe result is parsed.
            ldy   #0
:banner     lda   BANNER,y
            sta   $0400,y
            iny
            cpy   #BANNERLEN
            bne   :banner

            ;-- Row 1: "FREE=" + 3-digit decimal FREECOUNT + "
            ;BANKS".
            ldy   #0
:freelbl    lda   FREELBL,y
            sta   $0480,y
            iny
            cpy   #FREELBLLEN
            bne   :freelbl

            lda   FREECOUNT
            jsr   BIN2DEC                    ;-> DIGIT100/DIGIT1
                                             ;0/DIGIT1

            lda   DIGIT100
            ora   #$B0
            sta   $0480+FREELBLLEN
            lda   DIGIT10
            ora   #$B0
            sta   $0480+FREELBLLEN+1
            lda   DIGIT1
            ora   #$B0
            sta   $0480+FREELBLLEN+2

            ldy   #0
:suffix     lda   BANKSSFX,y
            sta   $0480+FREELBLLEN+3,y
            iny
            cpy   #BANKSSFXLEN
            bne   :suffix

            ;-- Row 2: "FIRST:" + up to MAXSHOW free bank
            ;numbers, hex,
            ;-- space-separated.
            ldy   #0
:firstlbl   lda   FIRSTLBL,y
            sta   $0500,y
            iny
            cpy   #FIRSTLBLLEN
            bne   :firstlbl

            ldx   #0                         ;X = index into
                                             ;FREELIST
            ldy   #FIRSTLBLLEN                ;Y = column offset
                                              ;into row 2
:showloop   cpx   FREECOUNT
            beq   :showdone
            cpx   #MAXSHOW
            beq   :showdone
            lda   FREELIST,x
            jsr   PrintHexY                   ;prints A at
                                              ;$0500+Y,$0500+Y+1
            iny
            iny
            iny                                ;2 hex digits + 1
                                               ;space
            inx
            bra   :showloop
:showdone

            ;-- Done. Nothing left for a test image to do.
:halt       jmp   :halt

*-- MAXSHOW: hoisted above its first use (EQU burn-down).
                                             ;bank numbers row 2
                                             ;has room to show

*---------------------------------------------------------------
* BIN2DEC -- convert A (0-255) to three decimal digits
* (DIGIT100/DIGIT10/ DIGIT1, each 0-9). Standard repeated-
* subtraction-with-correction idiom; verified by hand-trace
* against 127 -> 1/2/7 during development. Purely a display
* helper for this test harness -- deliberately NOT part of
* bankprobe.s, which stays free of any print/UI code (a real
* console driver is future kernel work, not this module's job).
*---------------------------------------------------------------
BIN2DEC     ldx   #$FF
:h100       inx
            sec
            sbc   #100
            bcs   :h100
            adc   #100
            sta   BCDTMP
            stx   DIGIT100
            lda   BCDTMP
            ldx   #$FF
:t10        inx
            sec
            sbc   #10
            bcs   :t10
            adc   #10
            sta   DIGIT1
            stx   DIGIT10
            rts

BCDTMP      ds    1
DIGIT100    ds    1
DIGIT10     ds    1
DIGIT1      ds    1

* See T.PROBETEST.TXT: "PrintHexY -- A  byte to"
PrintHexY   phx
            pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            tax
            lda   HEXDIGITS,x
            sta   $0500,y
            iny
            pla
            and   #$0F
            tax
            lda   HEXDIGITS,x
            sta   $0500,y
            dey
            plx
            rts

HEXDIGITS   asc   "0123456789ABCDEF"

            ;-- The probe + free-list allocator module itself.
            ;No ORG/DSK
            ;-- of its own -- see src/kernel/bankprobe.s's
            ;header for why
            ;-- its data tables (FREELIST/FREECOUNT/BANKTMP) are
            ;runtime-
            ;-- only $9xxx addresses rather than inline `ds`
            ;here (a
            ;-- 512-byte single-block boot has no room for a
            ;127-byte
            ;-- table baked into the image).
            put   ../kernel/bankprobe.s

            ;-- Pad to exactly 512 bytes (one disk block), same
            ;idiom as
            ;-- src/bootblock.s.
            ds    $0800+512-*
