*-----------------------------------------------------------------------------
* bootblock.s -- maux hello-world SmartPort boot block (block 0 of maux.po).
*
* Purpose: prove the merlin32 -> raw-block-image -> verilogapple pipeline
* end to end (task #1). This block does NOT load anything else, does NOT
* touch ProDOS, and does NOT call ROM COUT -- it prints "MAUX ALIVE" by
* writing straight to the 40-col text page at $0400 and then spins forever.
* The real bootstrap (loading a kernel image, filesystem, etc.) is later
* work; this only has to prove the rig is wired correctly.
*
* Entry conditions (cribbed from the working malisp bootblock, which cites
* this from direct observation of the //e boot ROM's SmartPort autostart
* path -- see ~/src/malisp/src/bootblock.s and library handle
* learning:01KWF4QBFJ8EJWK21JVP16VEM7 for the emulator side of "how do I
* even get this to run"):
*   - The boot ROM's autostart scan finds the SmartPort card (slot 7 in
*     verilogapple's mount_disk convention for non-.woz images), reads
*     block 0 of the mounted device to $0800, and JMPs to $0801.
*   - Byte at $0800 is a "chain count" some ROM variants check before
*     falling back to BASIC; malisp sets it to 1 (matching ProDOS) and so
*     do we, for the same reason -- untested whether verilogapple's ROM
*     actually inspects it, but it costs one byte to be safe.
*   - The CPU is NOT known to be in any particular state (zero page is not
*     preserved) -- interrupts are disabled and a fresh stack is set up
*     before doing anything else, same as malisp's START.
*
* HIGH-BIT GOTCHA (learning:01KW1GTYGZ9TE2ZGCDG0V2CNE0): merlin32's `asc`
* directive emits characters with the high bit SET, i.e. ASCII | $80 --
* which is exactly the Apple II text page's "normal" (uninverted,
* non-flashing) character encoding. So `asc "MAUX ALIVE"` below already
* produces the right bytes for a direct $0400 write; no manual `ora #$80`
* needed. ('M' = ASCII $4D -> merlin32 emits $CD, matching the task's
* worked example.)
*-----------------------------------------------------------------------------

            lst   off
            xc                              ;65C02 instruction set
            org   $0800
            dsk   ../build/bootblock.bin
            typ   $00

            ;-- Byte at $0800: chain count for the boot ROM (malisp
            ;-- precedent: 1, matching ProDOS's own boot block).
            dfb   $01

            ;-- Entry point. Boot ROM JMPs here ($0801) after loading
            ;-- block 0 to $0800.
START       sei
            ldx   #$FF
            txs
            cld

            ;-- Copy MSG (already high-bit-set by merlin32's `asc`) to the
            ;-- start of the 40-col text page, row 0 ($0400-$0427).
            ;-- The string sits ABOVE its copy loop (hopped
            ;-- by the `bra`) so MSGLEN precedes the `cpx` that
            ;-- uses it -- real Merlin-8 refuses an equ forward
            ;-- reference in an immediate (S9 EQU burn-down,
            ;-- 2026-08-29). Entry stays at $0801.
            bra   :copy
MSG         asc   "MAUX ALIVE"
MSGLEN      equ   *-MSG
:copy       ldx   #0
:loop       lda   MSG,x
            sta   $0400,x
            inx
            cpx   #MSGLEN
            bne   :loop

            ;-- Done. Nothing left for a hello-world boot block to do.
:halt       jmp   :halt

            ;-- Pad the assembled block to exactly 512 bytes (one disk
            ;-- block), same idiom as malisp's bootblock.s.
            ds    $0800+512-*
