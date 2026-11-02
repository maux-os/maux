*---------------------------------------------------------------
* procfile.s -- Process file-syscall delegate: the ProDOS-backed
* file calls PRC_FILECALL dispatches to (creat/unlink/rename/
* setpfx/getpfx/dotdot/gfi/pstat/open/close/read/write) plus the
* raw file-transfer helpers PRC_FILE_READ/PRC_FILE_WR use.
* Split out of process.s 2026-08-19 (this task's "ls -l"/"cd .."
* growth pushed process.s to 51703 bytes) so each kernel module
* fits real Merlin's 41215-byte source buffer
* (learning:01M051EM2HQ3ZVJTR1W9P3G86J). The top-level image
* PUTs each module in order; Merlin-8 cannot nest PUT.
* Full design notes: K.PROCESS.TXT (docs/a2/)
*---------------------------------------------------------------

*---------------------------------------------------------------
* File-call delegate for pipe objects. Non-pipe file calls still
* return the entry.s default "ProDOS unwired" error.
*---------------------------------------------------------------
PRC_FILECALL
            lda   K_CALLNUM
            cmp   #SYS_CREAT
            beq   :creat
            cmp   #SYS_UNLINK
            beq   :unlink
            cmp   #SYS_OPEN
            beq   :open
            cmp   #SYS_READ
            beq   :read
            cmp   #SYS_WRITE
            beq   :write
            cmp   #SYS_CLOSE
            beq   :close
            cmp   #SYS_RENAME
            beq   :rename
            cmp   #SYS_SFI
            beq   :setfi
            cmp   #SYS_SETPFX
            beq   :setpfx
            cmp   #SYS_GETPFX
            beq   :getpfx
            cmp   #SYS_GFI
            beq   :gfi
            cmp   #SYS_SET_MARK
            beq   :setmark
            cmp   #SYS_GET_MARK
            beq   :getmark
            cmp   #SYS_GET_EOF
            beq   :geteof
            cmp   #SYS_SET_EOF
            beq   :seteof
            cmp   #SYS_ONLINE
            beq   :online
            lda   #ERR_P8_UNWIRE
            jsr   PRC_FAIL_A
            rts
:online     jmp   PRC_ONLINE
:creat      jmp   PRC_CREAT
:unlink     jmp   PRC_UNLINK
:open       jmp   PRC_OPEN
:read       jmp   PRC_READ
:write      jmp   PRC_WRITE
:close      jmp   PRC_CLOSE
:rename     jmp   PRC_RENAME
:setfi      jmp   PRC_SETFI
:setpfx     jmp   PRC_SETPFX
:getpfx     jmp   PRC_GETPFX
:gfi        jmp   PRC_GFI
:setmark    jmp   PRC_SETMARK
:getmark    jmp   PRC_GETMARK
:geteof     jmp   PRC_GETEOF
:seteof     jmp   PRC_SETEOF

PRC_CREAT
            lda   #12
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_PATH
            bcc   :pathok
            rts
:pathok
* -- docs/STICKY.md sec 4: a CREATE that lands on a TAGGED
* -- pathname (sh's `>` does NOT unlink first: it is liba's
* -- CREAT, which ignores CREATE's $47) must drop that
* -- tag -- the write-path half of invalidation, alongside the
* -- raw-mtime compare on every candidate warm hit, and the
* -- half that catches a same-minute rewrite. Keyed on the
* -- CANONICAL path (LZ_INVAL_PB): a shell that never chdir'd
* -- hands over a relative name, and `> FILE` onto an existing
* -- program is exactly this call (liba CREAT: CREATE, whose
* -- $47 is ignored, then OPEN and SET_EOF 0).
            jsr   LZ_INVAL_PB
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            jsr   PMLI_CRT_CALL
            jmp   PCASE_CREAT      ;PRODOS-CASE.md: records
                                   ;the typed case, then falls
                                   ;to PRC_RET_MLI_A (procdev.s;
                                   ;a bare jmp in procdevs.s)

PRC_UNLINK
            lda   #3
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_PATH
            bcc   :pathok
            rts
:pathok     jsr   PRC_FILE_BUSY    ;open (resident/parked) =
            bcc   :notpark         ;refuse $50 (IB1/IB2)
            rts
:notpark
* -- the file being destroyed can never legitimately be run
* -- from a retained bank afterwards -- drop the tag, and
* -- release the bank it was holding (docs/STICKY.md sec 4).
* -- THE KEY IS PRC_CANON, NOT PRC_PATHBUF: tags are absolute,
* -- and a shell that never chdir'd leaves `rm FILE` relative,
* -- so the raw buffer can never match (docs/KGAPS-NOTES.md).
* -- The PRC_FILE_BUSY call above made the canonical form.
            jsr   LZ_INVAL_CN
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            jsr   PML_DSTRY_CLL
            jmp   PRC_RET_MLI_A

* See K.PROCESS.TXT: "PRC_RENAME -- MLI RENAME ($C2). The only"
PRC_RENAME
            lda   #5              ;param_count + 2 pointers
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_PATH   ;slot 0 <- pathname
            bcc   :path1ok
            rts
:path1ok    jsr   PCPY_NEW_PATH   ;slot 1 <- new_pathname
            bcc   :path2ok
            rts
:path2ok    jsr   PRC_FILE_BUSY    ;open (resident/parked) =
            bcc   :notbusy         ;refuse $50 (IB1/IB2)
            rts
:notbusy    jsr   PRC_ANCESTBSY  ;renaming a directory that
            bcc   :notpark         ;holds an open file would
            rts                    ;orphan its saved reopen
:notpark                           ;path -- refuse (IB3)
* -- a rename can invalidate a tag at EITHER name -- the old
* -- name no longer refers to that file, and the new name may
* -- shadow an unrelated stale tag (docs/STICKY.md sec 4). The
* -- OLD name's key is PRC_CANON (see PRC_UNLINK); the new name
* -- is whatever the caller typed.
            jsr   LZ_INVAL_CN
            clc
            lda   #<PRC_PATHBUF
            adc   #PRC_PATH2OFF
            sta   P_PTR1
            lda   #>PRC_PATHBUF
            adc   #0
            sta   P_PTR1+1
            jsr   LZ_INVAL
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            clc
            lda   #<PRC_PATHBUF
            adc   #PRC_PATH2OFF
            sta   PRC_PARM+MLI_NPATHLO
            lda   #>PRC_PATHBUF
            adc   #0
            sta   PRC_PARM+MLI_NPATHHI
            jsr   PMLI_RNM_CALL
            jmp   PCASE_RENAME     ;same, for the NEW name

* See K.PROCESS.TXT: "PRC_SETPFX / PRC_GETPFX -- the working"
* directory, which ProDOS keeps as ONE machine-wide prefix, not
* a per-process one -- a real gap for a second interactive
* shell, accepted while there is only ever one (sh). SET_PREFIX
* still validates the target is a real directory, for free.
*
* docs/CD.md is this task's own ruling record: a per-process cwd
* TABLE was tried (recording each chdir into the annex,
* CWD_TBL_ADDR/sched.s, then pinning this global prefix back to
* the boot value) and DROPPED -- the write into that table
* landed shifted into a neighbouring pid's slot, reproducibly,
* with two independently-written primitives (a hand-rolled
* RAMWRTAUX/ (ptr),y loop and a BankCopy-based rewrite alike),
* and root cause was not found within this task's budget. `cd
* ..`/`cd ../..` therefore resolve against ProDOS's own LIVE
* prefix (PRC_DOTDOT, below) instead of a recorded table --
* read-only GET_PREFIX use, proven reliable everywhere else in
* this tree.
PRC_SETPFX
* -- Capture ProDOS's prefix on the FIRST chdir -- the boot
* -- volume, since nothing has moved it. Not at PRC_INIT: images
* -- that never wire ProDOS run that path too, and an MLI call
* -- there hangs them (check-process, found the hard way). Bare
* -- `cd` (docs/CD.md) returns here, so this doubles as the
* -- "go home" target.
            lda   PRC_PFXSAVE
            bne   :haveboot
            lda   #1
            sta   PRC_PARM
            lda   #<PRC_PFXSAVE
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PFXSAVE
            sta   PRC_PARM+MLI_PATHHI
            stz   PRC_PFXSAVE
            jsr   PMLI_GPFX_CL
:haveboot
            lda   #3              ;count + pathname ptr
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_RAW     ;-> PRC_PATHBUF, virtual
            bcc   :pathok
            rts
:pathok     lda   PRC_PATHBUF
            bne   :havetgt
* -- bare `cd`: go to the boot prefix. Nothing before boot ever
* -- moves ProDOS's own prefix, so the two candidate targets the
* -- task raised -- "boot volume root" and "boot prefix" -- are
* -- the SAME path on this system. It is PHYSICAL already.
            stz   VR_PEND
            ldy   #0
:cpboot     lda   PRC_PFXSAVE,y
            sta   PRC_PATHBUF,y
            cpy   PRC_PFXSAVE
            beq   :havetgt
            iny
            bra   :cpboot
* -- docs/VROOT.md: `..` is resolved in USERLAND (liba MKPATH)
* -- on the VIRTUAL spelling; the kernel's own PRC_DOTDOT popped
* -- ProDOS's pinned boot prefix, never the caller's cwd, and is
* -- gone. A VIRTUAL path is tested for "/", "/dev", "/mnt"
* -- first (segment-resident, no SET_PREFIX), then made
* -- physical.
:havetgt    lda   VR_PEND
            beq   :realsp
            jsr   PRC_SYNAPPLY
            bcc   :xl
            lda   #0
            jmp   PRC_RET_MLI_A
:xl         jsr   VR_XLATE_P
            bcc   :realsp
            rts
:realsp     lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
*-- THE CALLER'S PID IS CAPTURED BEFORE THE MLI CALL, not read
*-- back after it. PMLI_SPFX_CL clears K_NOSWITCH on the way
*-- out, so a context switch may land between SET_PREFIX
*-- returning and the record below -- and CWD_WRITE takes a
*-- pid. Reading K_CURPID after the call would write ANOTHER
*-- PROCESS'S
*-- SLOT, which is exactly the symptom docs/CD.md recorded as
*-- unexplained ("landed in the neighbouring pid's slot") when
*-- this was first attempted. Cheap insurance either way.
            lda   K_CURPID
            sta   PRC_CWDPID
            jsr   PMLI_SPFX_CL     ;validates the directory
                                    ;exists, for free
            bne   :spfxdone        ;failed -- record nothing
            jsr   PRC_CWD_STORE
            jsr   PRC_PIN_BOOT     ;the cwd is OURS now, not
                                    ;ProDOS's -- see its header
            lda   #0               ;SET_PREFIX succeeded; A is
                                    ;PRC_RET_MLI_A's argument
:spfxdone   jmp   PRC_RET_MLI_A

* -- PRC_SYNROOT MOVED to kdevblk.s (the segment) + procdev.s (a
* -- flat KSEG_CALL trampoline of the same name) + procdevs.s (a
* -- flat "always A=0" stub for the ~31 non-play images),
* -- 2026-09-30 (docs/DEVFS.md/DEVFS-NOTES.md): pure string
* -- compare (PDEV_FOLD, called by ordinary `jsr` -- segment
* -- calling flat needs no trampoline), no MLI call, and
* -- MAUXPLAY.SYSTEM had no flat headroom left (check-kernel-
* -- images). The stub's "always A=0, not synthetic" answer is
* -- exactly today's pre-devfs PRC_SETPFX behaviour for the 31
* -- images that never type `cd /`/`cd /dev` in their own test
* -- scripts.

*---------------------------------------------------------------
* PRC_PIN_BOOT -- put ProDOS's ONE machine-wide prefix back to
* the boot value, every time a process chdirs.
*
* THIS IS WHAT MAKES THE CWD PER-PROCESS. Recording the path
* (PRC_CWD_STORE) only makes the table TRUE; while ProDOS's own
* prefix also moved, a process that has never chdir'd -- so has
* an EMPTY slot and falls back to that prefix -- still sees
* wherever some OTHER process last went. That is the leak
* `( cd X ; ... )` exposed, and pinning is what closes it: the
* global returns to boot, an empty slot means "boot", and every
* non-empty slot is consulted by PRC_ABSPATH instead.
*
* Skipped when PRC_PFXSAVE is empty, which means the boot
* capture in PRC_SETPFX has not run yet -- SET_PREFIX with a
* zero-length path CLEARS ProDOS's prefix rather than restoring
* anything, which would be worse than leaving it moved.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRC_PIN_BOOT
            lda   PRC_PFXSAVE      ;boot prefix not captured yet
            beq   :nopin           ;-- leave ProDOS alone
            lda   #1
            sta   PRC_PARM
            lda   #<PRC_PFXSAVE
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PFXSAVE
            sta   PRC_PARM+MLI_PATHHI
            jmp   PMLI_SPFX_CL     ;tail call
:nopin      rts

*---------------------------------------------------------------
* PRC_CWD_STORE -- record the caller's new working directory in
* the per-pid annex table (CWD_TBL_ADDR, sched.s). Called only
* after a SET_PREFIX that SUCCEEDED, with the caller's pid
* already in PRC_CWDPID.
*
* IT READS THE PREFIX BACK RATHER THAN RECORDING WHAT WAS ASKED
* FOR. The argument may be relative, may lack a trailing '/',
* may be spelled in any case ProDOS accepts -- GET_PREFIX
* returns the ONE canonical absolute form ProDOS actually
* resolved, which is the only spelling PRC_ABSPATH can safely
* compose against. It costs one MLI round trip per `cd`, which
* is a rounding error next to the directory read SET_PREFIX just
* did to validate the target.
*
* CWD PATHS ARE LIMITED TO 63 CHARACTERS, and that is a real
* fence rather than an oversight: a slot is CWD_ENT_SIZE (64)
* bytes and the buffer is LENGTH-PREFIXED, so 63 characters plus
* their length byte is exactly what fits. ProDOS allows 64, so
* the last one is refused here -- a 63-character DIRECTORY
* leaves nothing to name a file inside it anyway, so nothing
* usable is lost. Recording a truncated path would resolve to a
* different, possibly real, directory -- the wrong-answer shape
* this tree refuses everywhere else.
*
* A failure to record leaves the slot UNCHANGED and the `cd`
* itself still succeeds: ProDOS's own prefix moved either way,
* and while that prefix is still the fallback (see
* PRC_ABSPATH), an unrecorded cwd degrades to today's behaviour
* rather than to a wrong directory.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRC_CWD_STORE
            lda   #1               ;GET_PREFIX: param_count 1 +
            sta   PRC_PARM         ;  a buffer pointer
            lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            stz   PRC_PATHBUF      ;0 if the MLI writes none
            jsr   PMLI_GPFX_CL
            bne   :nostore
*-- STORED WITH ProDOS's OWN TRAILING '/', deliberately.
*-- PRC_ABSPATH tests the last byte and skips its own separator
*-- when one is already there (`:nosep`), so the canonical form
*-- GET_PREFIX answers with composes correctly as-is.
*--
*-- A trailing-slash STRIP was written here and reverted, and
*-- the reason is a MERLIN DIALECT FACT worth stating where the
*-- next reader will look: in Merlin a double-quoted character
*-- is ALREADY HIGH-BIT, so this file's `cmp #"/"+$80` assembles
*-- to `C9 2F` -- it compares LOW ASCII $2F, the encoding MLI
*-- pathnames actually use, and `+$80` is what wraps it down
*-- there. Read as "high-bit slash" it looks like a mismatch
*-- against GET_PREFIX's output and invites a fix to code that
*-- was correct. The strip was caught only because, written as
*-- `cmp #"/"` (= $AF), it silently never fired.
            lda   PRC_PATHBUF      ;the length byte
            beq   :nostore         ;empty -- nothing to record
            cmp   #CWD_ENT_SIZE    ;length + its own byte must
            bcs   :nostore         ;  fit the slot (see header)
            tay                     ;copy bytes 0..length, the
:cp         lda   PRC_PATHBUF,y    ;  length byte included
            sta   K_CWD_BUF,y
            dey
            bpl   :cp
            bra   :store
*-- COULD NOT RECORD: clear the slot rather than leave the
*-- PREVIOUS path in it. The header used to reason that a
*-- failed record "degrades to today's behaviour" -- wrong, and
*-- found by review: PRC_ABSPATH prefers a non-empty slot, so
*-- a STALE one silently resolves relative opens into the
*-- directory the process used to be in. Empty means "no cwd
*-- recorded", falls back to ProDOS's own prefix, and is the
*-- honest answer. Reachable whenever GET_PREFIX answers 64
*-- characters, the one length a 64-byte length-prefixed slot
*-- cannot hold.
:nostore    stz   K_CWD_BUF        ;length 0 = "none recorded"
:store      lda   PRC_CWDPID       ;ONE write, both outcomes
            jmp   CWD_WRITE        ;tail call

*-- GET_PREFIX is the only delegate call that hands a STRING
*-- back to the caller, so it is the copy-OUT direction: let the
*-- MLI fill a kernel buffer, then bankcopy it into the process.
PRC_GETPFX
            lda   #3              ;param_count + data_buffer ptr
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+MLI_PATHLO
            sta   PRC_USER_PTR
            lda   PRC_PARM+MLI_PATHHI
            sta   PRC_USER_PTR+1
*-- ANSWER FROM THE CALLER'S OWN SLOT when it has one. This is
*-- the syscall boundary where a machine-wide prefix becomes a
*-- per-process working directory: userland asks GET_PREFIX and
*-- gets ITS cwd, so `pwd` reports the truth and liba's MKPATH
*-- -- which resolves `.`/`..` against this answer for all 29
*-- programs that call it -- resolves them per-process too.
*-- ProDOS's own prefix is pinned to boot (PRC_PIN_BOOT) and is
*-- now an implementation detail, consulted only for a process
*-- that has never chdir'd, whose slot is empty and for which
*-- "boot" is the right answer.
            lda   K_CURPID
            jsr   CWD_READ
            lda   K_CWD_BUF
            beq   :askmli
            tay                     ;copy bytes 0..length, the
:cpcwd      lda   K_CWD_BUF,y      ;  length byte included
            sta   PRC_PATHBUF,y
            dey
            bpl   :cpcwd
            bra   :gotpfx
:askmli     lda   #<PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PRC_PARM+MLI_PATHHI
            stz   PRC_PATHBUF     ;0 if MLI writes none
            jsr   PMLI_GPFX_CL
            beq   :gotpfx
            jsr   PRC_FAIL_A
            rts
:gotpfx     jsr   VR_REV           ;physical -> virtual
            bcc   PRC_PB_OUT
            rts                    ;too long to spell: failed
*-- PRC_PB_OUT -- copy the length-prefixed string in PRC_PATHBUF
*-- out to the caller (PRC_USER_PTR); SYS_VROOT's rows reuse it.
PRC_PB_OUT  jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PRC_PATHBUF
            sta   K_BC_SRCADDR
            lda   #>PRC_PATHBUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   PRC_PATHBUF     ;length byte, plus itself
            inc
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            rts
:copied     jsr   PRC_RET_OK0
            rts

* -- PRC_ONLINE MOVED to kdevblk.s (the segment) + procdev.s (a
* -- flat KSEG_CALL trampoline of the same name) + procdevs.s (a
* -- flat ERR_NOSYS stub for the ~31 non-play images),
* -- 2026-09-30
* -- (docs/DEVFS.md/DEVFS-NOTES.md): same reason and same shape
* -- as PRC_DEVLIST/PRC_ROOTLIKE/PRC_SYNROOT's own moves --
* -- MAUXEDTEST/MAUXEXPR/MAUXFINDTEST/MAUXTESTEV.SYSTEM all grew
* -- past PMLI_IBF_BASE too (check-kernel-images), not just
* -- MAUXPLAY. Calling PMLI_ONLN_CL (procmli.s, flat) from the
* -- segment is exactly PRC_RAMREDISC's (kbye.s) own established
* -- pattern -- that wrapper's `lda LCBANK1_RAM` epilogue
* -- RESTORES the segment's own bank on return (KSEG_ORG's
* -- segment lives in LC BANK 1; bank 2 is the flat kernel's own
* -- "steady state" -- KSEG_CALL's trampoline comment,
* -- procdev.s),
* -- it does not evict it.
