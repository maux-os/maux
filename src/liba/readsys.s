*---------------------------------------------------------------
* readsys.s -- the three raw syscall gates that readsyn.s's
* walkers call, split out of it (KFIX8, docs/KFIX8-NOTES.md
* sec 2). mount and umount need these and nothing else of
* readsyn.s, and used to carry its ~790 other bytes (the
* synthetic directory reader) dead. Every program that puts
* readsyn.s puts this right after it; mount and umount put
* THIS INSTEAD of readsyn.s. It writes RD_RPARM_REQ, so it is
* an arena user (check_purity.py ARENA_USERS): the program
* must put libabss.s.
*---------------------------------------------------------------
* SC_ONLINE/SC_DEVLIST -- the raw syscall gates for SYS_ONLINE
* ($C5, PER UNIT ONLY) and SYS_DEVLIST (docs/DEVFS.md). Live
* HERE, not in src/liba/syscalls.s or syscallp.s (2026-09-30,
* docs/DEVFS-NOTES.md): as.s `put`s syscalls.s for its own file
* I/O but not readdir.s/readsyn.s, and its `err */SYMADR`
* arena-overlay ceiling has no slack -- adding these two
* wrappers there broke
* that build for every one of ITS consumers, not just the 7
* programs that actually need `/dev`. This file is the common
* denominator of everything that walks or mounts the virtual
* directories: cp/df/diff/du/find/ld/ls/mv/rm and sh's glob
* put it right after readsyn.s, mount and umount put it ALONE
* (since KFIX8), so they are paid for only by that set, same
* `jsr $FF00` shape as every other SC_* wrapper.
*
* SC_ONLINE -- IN: A/X = lo/hi of the caller's {param_count=2,
* unit_num, buffer ptr} 4-byte parm (RD_RPARM is the one
* composed caller, RD_READROOT). OUT: A = the MLI status (0 =
* ok), carry as PMLI_ONLN_CL (kernel, procmli.s) leaves it.
*
* SC_DEVLIST -- IN: PTR0 = the caller's buffer (>= 16 bytes,
* DEVLST's own max). OUT: A = bytes written (DEVCNT+1), carry
* clear. No leading count byte -- a maux call, not a delegate.
*---------------------------------------------------------------
SC_ONLINE   ldy   #SYS_ONLINE
            jsr   $FF00
            rts

SC_VROOT    ldy   #SYS_VROOT       ;A/X = a 4-byte parm
            jsr   $FF00
            rts

SC_DEVLIST  lda   PTR0
            sta   RD_RPARM_REQ
            lda   PTR0+1
            sta   RD_RPARM_REQ+1
            lda   #<RD_RPARM_REQ
            ldx   #>RD_RPARM_REQ
            ldy   #SYS_DEVLIST
            jsr   $FF00
            rts
