*---------------------------------------------------------------
* brk.s -- the heap primitives: SC_BRK (set the break to an
* absolute address) and SC_SBRK (grow it by a byte count and
* hand back the base of the block). Both ride the SAME kernel
* call, SYS_BRK (5, inc/sc.proc.equ) -- they differ
* only in the mode byte the kernel reads from PROCPARM+2. See
* src/kernel/process.s PRC_BRK for the contract.
*
* ITS OWN MODULE, not a pair of routines bolted onto
* syscallp.s: `make check-rel` proved Merlin's linker includes
* WHOLE modules, so a liba module's size is what a program pays
* (docs/REL-LIBA-SPIKE.md, and check_modules.py's own
* check_userland docstring). Only sort and ed have a heap;
* charging every process-call user for these routines -- or
* charging these two for SC_SPAWN/SC_WAIT/SC_PIPE/SC_PSTAT/
* SC_CLOCK, which is what putting them in syscallp.s would have
* done -- is the packaging mistake that gate exists to catch.
* SC_BRK MOVED HERE from syscallp.s (2026-08-22), where it had
* sat unused and unfinished since task #3: no program had ever
* called it, because PRC_BRK was an ERR_NOSYS stub.
*
* PRECONDITION ON THE INCLUDER: PROCPARM (src/liba/syscalls.s)
* and inc/sc.proc.equ must both be in scope. Every
* program that `put`s this file also `put`s syscalls.s, which
* SC_EXIT alone already requires of it.
*---------------------------------------------------------------

*---------------------------------------------------------------
* SC_BRK -- brk(addr). Sets the break to the first page
* boundary at or above PTR0. This is how a program ESTABLISHES
* its heap: it is the only call that can, because only the
* program knows where its own uncleared `dum` region ends. The
* kernel refuses SC_SBRK until this has been done once.
* IN:  PTR0 = the desired break address
* OUT: carry clear, PTR0 = the PREVIOUS break ($0000 if none);
*      carry set, A = errno (ERR_NOMEM past $BF00, ERR_INVAL
*      below $0800) and the break is UNCHANGED
*---------------------------------------------------------------
SC_BRK      lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            stz   PROCPARM+2     ;mode 0 -- value is an ADDRESS
            bra   SCBRK_CALL

*---------------------------------------------------------------
* SC_SBRK -- sbrk(delta). Reserves `delta` MORE bytes above the
* current break, rounded up to a whole page, and returns the
* base of that block -- V6 sbrk exactly. delta 0 is a pure
* query: it changes nothing and returns the current break, so
* it is also how a program asks "how much have I taken".
* IN:  PTR0 = byte count
* OUT: carry clear, PTR0 = base address of the new block;
*      carry set, A = errno and NOTHING was allocated
*---------------------------------------------------------------
SC_SBRK     lda   PTR0
            sta   PROCPARM+0
            lda   PTR0+1
            sta   PROCPARM+1
            lda   #1
            sta   PROCPARM+2     ;mode 1 -- value is a COUNT

SCBRK_CALL  lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_BRK
            jsr   $FF00          ; THE gate
            bcs   :failed
            lda   PROCPARM+0     ;kernel wrote the old break
            sta   PTR0           ;  back over the request
            lda   PROCPARM+1
            sta   PTR0+1
            clc
:failed     rts
