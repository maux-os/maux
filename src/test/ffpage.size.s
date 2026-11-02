*---------------------------------------------------------------
* ffpage.size.s -- task #3's byte-budget acceptance gate: proves
* src/kernel/ffpage.s assembles to EXACTLY 256 bytes at its real
* address.
*
* `org $FF00`, `put`s ffpage.s in directly -- no kernel, no
* dispatch table, nothing else. KRN_ENTRY/KRN_IRQ_ENTRY
* are equ'd to a placeholder address (this file never runs; the
* JMPs inside ffpage.s just need SOME resolvable target for
* merlin32 to assemble against). `make check-syscall` asserts
* `wc -c build/ffpage_size.bin` == 256.
*
* Does NOT `use inc/memmap.equ` -- see ffpage.s's header:
* memmap.equ's `dum $FF00...dend` block defines bare
* SYSCALL_ENTRY/IRQ_ENTRY/etc. as OFFSET CONSTANTS, which would
* collide with... actually it wouldn't collide with ffpage.s's
* FFP_-prefixed labels, but this file still keeps its own
* minimal equates rather than pulling in memmap.equ's much
* larger symbol set, since all it needs is the five switch
* addresses ffpage.s's stubs reference. Matches memmap.equ's own
* documented values exactly (RAMRDMAIN=$C002 etc.) -- a comment,
* not a `use`, is the cross-check here, since this file's whole
* point is testing ffpage.s in ISOLATION.
*---------------------------------------------------------------

            lst   off
            xc                              ;65C02 instruction
                                            ;set
            org   $FF00
            dsk   ../../build/ffpage_size.bin
            typ   $00

* -- softswitch addresses ffpage.s's stubs reference (values
* match -- inc/memmap.equ verbatim -- see that file's own
* section 4). --
RAMRDMAIN   equ   $C002
RAMRDAUX    equ   $C003
RAMWRTMAIN  equ   $C004
RAMWRTAUX   equ   $C005
BANKSEL     equ   $C073

* -- placeholder external jump targets (this image never
* executes) --
KRN_ENTRY      equ   $0800
KRN_IRQ_ENTRY  equ   $0800

            put   ../kernel/ffpage.s
