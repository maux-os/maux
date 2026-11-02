*---------------------------------------------------------------
* syscalls.s -- the FILE-call syscall gate stubs, plus SC_EXIT.
* THE CHOKE POINT, paired with inc/sc.file.equ
* (canonical file-call numbers -- real ProDOS MLI numbers
* verbatim -- ratified task #3, see docs/SYSCALL.md). Every
* SC_* routine here issues the same gate; nothing outside this
* file/syscallp.s issues that JSR, and nothing outside src/liba
* references a SYS_* call number (enforced by `make
* check-userland`'s grep gate).
*
* SPLIT 2026-08-21 (docs/FAT.md sec 12): the maux PROCESS calls
* (spawn/wait/pipe/brk/pstat/clock -- no MLI equivalent,
* dispatched via the kernel's K_DISP table, numbers from
* inc/sc.proc.equ) moved to syscallp.s. Measured: 30 of
* 33 utilities never call a process routine, so they no longer
* pay to link one. See src/liba/syscallp.s's header.
*
* SC_EXIT STAYS HERE despite being a process call by that same
* kernel boundary (SYS_EXIT is dispatched via K_DISP, not
* PRC_FILECALL) -- it is the one universally-needed exception.
* stdio.s's EXIT (the flush-on-exit wrapper every program calls)
* JSRs SC_EXIT directly, so moving it to syscallp.s would force
* every one of the 30 file-only utilities to `put` syscallp.s
* anyway, defeating the split. PROCPARM lives here for the same
* reason: SC_EXIT needs it, and check_modules.py's
* check_userland() forbids a symbol defined in two liba modules.
* syscallp.s's process-call routines reference PROCPARM without
* redeclaring it; every consumer of syscallp.s already `put`s
* this file too.
*
* Full design notes: L.SYSCALLS.TXT (docs/a2/)
*---------------------------------------------------------------

* -- PROCPARM (6 bytes, the process-call scratch parmlist shared
* -- with syscallp.s -- see header) moved to
* -- src/liba/libabss.s (docs/STICKY.md sec 21). Every wrapper
* -- fills the fields it uses before its own call, so it needs
* -- no zero start; it only needed to stop being writable text.

*---------------------------------------------------------------
* SC_EXIT -- exit(status). Does not return.
* IN: A = status byte
*---------------------------------------------------------------
SC_EXIT     sta   PROCPARM+0
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_EXIT
            jsr   $FF00
            ;not reached -- defensive halt in case the kernel
            ;ever returns
:hang       jmp   :hang

SC_CREAT    ldy   #SYS_CREAT     ; MLI CREATE ($C0)
            jsr   $FF00
            rts

SC_UNLINK   ldy   #SYS_UNLINK    ; MLI DESTROY ($C1)
            jsr   $FF00
            rts

SC_RENAME   ldy   #SYS_RENAME    ; MLI RENAME ($C2)
            jsr   $FF00          ; same directory only (P8 TRM)
            rts

SC_SETPFX   ldy   #SYS_SETPFX    ; MLI SET_PREFIX ($C6)
            jsr   $FF00
            rts

SC_GETPFX   ldy   #SYS_GETPFX    ; MLI GET_PREFIX ($C7)
            jsr   $FF00
            rts

SC_OPEN     ldy   #SYS_OPEN      ; MLI OPEN ($C8)
            jsr   $FF00
            rts

SC_READ     ldy   #SYS_READ      ; MLI READ ($CA)
            jsr   $FF00
            rts

SC_WRITE    ldy   #SYS_WRITE     ; MLI WRITE ($CB)
            jsr   $FF00
            rts

SC_CLOSE    ldy   #SYS_CLOSE     ; MLI CLOSE ($CC)
            jsr   $FF00
            rts

SC_GFI      ldy   #SYS_GFI       ; MLI GET_FILE_INFO ($C4)
            jsr   $FF00          ; A/X already point at the
            rts                  ;caller's PCOUNT_GFI-shaped
                                 ;parm

* -- SC_ONLINE/SC_DEVLIST MOVED to readdir.s, 2026-09-30
* -- (docs/DEVFS.md/DEVFS-NOTES.md): as.s `put`s this file (for
* -- SC_OPEN/READ/WRITE/CLOSE/GFI, its own file I/O) but not
* -- readdir.s or readdir.equ, and as.s's own `err */SYMADR`
* -- ceiling (its arena-overlay guard, this file's header) has
* -- NO slack -- the ~28 bytes these two wrappers cost here
* -- broke that build for every consumer of THIS file, not just
* -- the 7 that actually need them. readdir.s is the exact
* -- common denominator (its 7 consumers: cp/du/find/ld/ls/mv/
* -- rm), so the two wrappers live there now, `jsr $FF00` and
* -- all -- the same shape as every routine on this page, just
* -- paid for by the narrower set that actually uses `/dev`.

* See L.MLIE.TXT / mli.equ PCOUNT_SFI: PCOUNT_SFI-shaped parm --
* chmod.s's own read-modify-write is the only caller.
SC_SFI      ldy   #SYS_SFI       ; MLI SET_FILE_INFO ($C3)
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_SETMARK/SC_GETMARK/SC_GETEOF/SC_SETEOF -- the seek family
* (docs/FLEET.md "`>>` and the seek family"; PRC_SETMARK/
* PRC_GETMARK/PRC_GETEOF/PRC_SETEOF, src/kernel/procfile.s).
* Bare gates, same shape as SC_GFI directly above: A/X already
* point at the caller's 5-byte (param_count, fd, 3-byte value)
* parm -- see src/liba/seek.s's LSEEK for the one composed
* caller.
*
* REGISTER DISCIPLINE (docs/TASKS.md's own "liba's SC_* wrappers
* clobber Y" finding -- FOUR prior instances of a gate/stub not
* preserving what its caller needed across it): these four are
* bare gates like every other file-call SC_*, so they carry the
* SAME clobber -- Y holds the call number going in and is
* never restored, and $FF00 itself does not preserve it
* either. CALLERS MUST NOT rely on Y surviving a call to any
* of these four (LSEEK does not).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
SC_SETMARK  ldy   #SYS_SET_MARK  ; MLI SET_MARK ($CE)
            jsr   $FF00
            rts

SC_GETMARK  ldy   #SYS_GET_MARK  ; MLI GET_MARK ($CF)
            jsr   $FF00
            rts

SC_GETEOF   ldy   #SYS_GET_EOF   ; MLI GET_EOF ($D1)
            jsr   $FF00
            rts

SC_SETEOF   ldy   #SYS_SET_EOF   ; MLI SET_EOF ($D0)
            jsr   $FF00
            rts

*---------------------------------------------------------------
* SC_FDSTAT -- fdstat(fd): what kind of object does one of THIS
* process's fd slots hold. maux's isatty. Lives here in the
* base wrapper file (not syscallp.s) so ed -- which puts only
* syscalls.s -- can call it too: edparse.s's ED_ERR probes
* whether stdin is a tty (ex `-s` script silence), and the
* choke-point gate forbids ed/ex/vi issuing $FF00 themselves
* (moved 2026-09-07, was in syscallp.s).
*
* IN:  A = fd.
* OUT: carry clear, A = the type -- >= FD_DEV_BASE (test the
*      high bit) is a DEVICE/tty, else one of sc.proc.equ's
*      FDST_PIPE_R/FDST_PIPE_W/FDST_FILE. Carry set, A = errno
*      (closed fd, or fd >= 8).
*
* One byte in, one byte out; the fd is register-passed because
* callers have it in a register already. CLOBBERS: X, Y.
*---------------------------------------------------------------
SC_FDSTAT   sta   PROCPARM+0     ;fd
            lda   #<PROCPARM
            ldx   #>PROCPARM
            ldy   #SYS_FDSTAT
            jsr   $FF00
            rts
