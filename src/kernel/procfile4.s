*---------------------------------------------------------------
* procfile4.s -- the second half of the file-syscall brokers.
*
* SPLIT OUT OF procfile.s (S9 L4, 2026-08-29): that file's own
* stripped text was 15468 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
* PRC_DOTDOT is gone (docs/VROOT.md): userland resolves `..`.
*---------------------------------------------------------------
* PRC_GFI -- MLI GET_FILE_INFO ($C4), stat() for userland (task:
* "wire GET_FILE_INFO into the kernel file-syscall broker and
* liba", 2026-08-19). Same shape as every other delegated file
* call: copy the caller's parmlist header, resolve the pathname
* via PCPY_MLI_PATH/PRC_ABSPATH, point PML_GFI_PARMS's pathname
* pointer at the kernel's own PRC_PATHBUF for the MLI's own
* dereference, call the interrupt-bracketed wrapper, then copy
* back ONLY the RESULT fields -- never offsets 0..2
* (param_count, pathname pointer), which the OPEN handler's
* ref_num-only copyback established as the rule (see that
* routine's own long comment, and SH-DESIGN.md, for the bug a
* whole-parmlist copyback caused: it silently corrupts a reused
* static parmlist's pathname pointer to a kernel-internal
* address).
*
* PML_GFI_PARMS is the SAME kernel-owned struct sticky.s (task
* #15) uses for its own warm-spawn mtime probe -- reused, not
* duplicated, per this task's own instructions. Safe to share:
* both sticky.s's calls (from PRC_SPAWN) and this handler (from
* PRC_FILECALL) run in process context only, on the one call
* stack a running process has -- there is no reentrancy for
* either to race against, and every field PML_GFI_PARMS carries
* is fully overwritten by the MLI call itself on every use, so
* no stale field from a previous caller (sticky.s or this) can
* leak into the next.
*---------------------------------------------------------------
PRC_GFI
            lda   #3              ;param_count + pathname ptr
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    jsr   PCPY_MLI_RAW
            bcc   :pathok
            rts
:pathok     lda   VR_PEND           ;"/", "/dev", "/mnt":
            beq   :real             ;are directories the kernel
            jsr   PRC_SYNCLASS      ;answers for itself (result
            bne   :gfiok            ;fields filled in, no MLI)
            jsr   VR_XLATE_P
            bcc   :real
            rts
:real       lda   #<PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHHI
            jsr   PMLI_GFI_CALL
            beq   :gfiok
            jmp   PRC_FAIL_A
:gfiok      jsr   PRC_SEL_CRBNK
            sta   P_BANK
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            clc
            lda   #<PML_GFI_PARMS
            adc   #MLI_GFI_ACC
            sta   K_BC_SRCADDR
            lda   #>PML_GFI_PARMS
            adc   #0
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            clc
            lda   K_PARMLO
            adc   #MLI_GFI_ACC
            sta   K_BC_DSTADDR
            lda   K_PARMHI
            adc   #0
            sta   K_BC_DSTADDR+1
            lda   P_BANK
            sta   K_BC_DSTBANK
            lda   #MLI_GFI_RLEN
            sta   K_BC_LEN
            stz   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   #ERR_INVAL
            jmp   PRC_FAIL_A
:copied     jsr   PRC_RET_OK0
            rts

* See K.PROCESS.TXT: "PRC_PSTAT -- read one process-table slot."
*
* PS-ARGS (docs/PS-ARGS.md, PS-ARGS-NOTES.md). The slot byte is
* slot (bits 0-5) + MODE (bits 6-7), and the answer is ALWAYS
* copied to the caller's buffer, so a caller that never sets a
* mode bit is byte-for-byte the old call:
*   mode 0 ($00)  the PSTAT_LEN head record (PID STATE WCHAN
*                 BANK PARENT EXITSTAT)
*   mode 1 ($40)  PSTAT_BLK raw bytes of that process's own
*                 $0200.. (its argv block as spawn staged it)
*   mode 2 ($80)  the spawned pathname's tag, LZ_PTH_SIZE bytes
*                 (length byte + chars), from the lazy-free slot
*                 for that bank; ERR_INVAL if the bank has none
* Modes 1 and 2 refuse an unused slot. Only the kernel can read
* another bank, so the kernel moves the bytes; what they MEAN
* (validate, join, truncate, fall back) is ps's job -- the
* flat image has 9 B of ratchet slack, not a validator.
PRC_PSTAT
            lda   #3              ;slot index + buffer pointer
            jsr   PCPI_CALLPARM
            bcc   :parmsok
            rts
:parmsok    lda   PRC_PARM+0
            err   PCB_COUNT/$41    ;the mask below needs <= $40
            and   #$3F
            tax
            cmp   #PCB_COUNT
            bcs   :bad
            lda   PRC_PARM+1      ;stash the buffer first, in
            sta   K_BC_DSTADDR    ;  BankCopy's own cell: PCB
            lda   PRC_PARM+2      ;  reads flip banks
            sta   K_BC_DSTADDR+1

            txa
            jsr   PCB_PTR_FOR
            stz   BANKSEL         ;annex holds the PCB array
            lda   #PCB_PID
            ldx   #7              ;PID..EXITSTAT, one read
            jsr   PCB_RD_FIELDS
            lda   K_PCB_SCRATCH+6 ;EXITSTAT closes the
            sta   K_PCB_SCRATCH+5 ;  gap SAVEDSP leaves

            jsr   PRC_SEL_CRBNK
            sta   K_BC_DSTBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            sta   K_BC_SRCKIND
            lda   K_PCB_SCRATCH+3 ;BANK: mode 1's source (and
            sta   K_BC_SRCBANK    ;  ignored for a MAIN source)
            stz   K_BC_LEN+1
            lda   PRC_PARM+0
            and   #$C0
            bne   :other
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<K_PCB_SCRATCH
            sta   K_BC_SRCADDR
            lda   #>K_PCB_SCRATCH
            sta   K_BC_SRCADDR+1
            lda   #PSTAT_LEN
            sta   K_BC_LEN
            bra   :go
:bad        lda   #ERR_INVAL
            jmp   PRC_FAIL_A
:other      ldx   K_PCB_SCRATCH+1 ;STATE
            beq   :bad            ;unused slot
            cmp   #$40
            bne   :path
            stz   K_BC_SRCADDR
            lda   #>PRC_LOWFREE
            sta   K_BC_SRCADDR+1
            lda   #<PSTAT_BLK
            sta   K_BC_LEN
            lda   #>PSTAT_BLK
            sta   K_BC_LEN+1
            bra   :go
:path       lda   K_BC_SRCBANK
            jsr   LZ_FIND_BNK     ;X = slot
            bcs   :bad            ;untagged: ps prints `?`
            stz   K_BC_SRCBANK    ;the annex holds the tags
            txa
            jsr   LZ_ENT_ADDR
            lda   LZ_ENTADR
            sta   K_BC_SRCADDR
            lda   LZ_ENTADR+1
            sta   K_BC_SRCADDR+1
            lda   #LZ_PTH_SIZE
            sta   K_BC_LEN
:go         jsr   BankCopy
            lda   K_BC_ERR
            bne   :bad
            jmp   PRC_RET_OK0

* -- PRC_DEVLIST MOVED to kdevblk.s (the segment) + procdev.s (a
* -- flat KSEG_CALL trampoline of the same name) + procdevs.s (a
* -- flat ERR_NOSYS stub for the ~31 non-play images),
* -- 2026-09-30
* -- (docs/DEVFS.md/DEVFS-NOTES.md): the real body pure-reads
* -- ProDOS's global page (no MLI call, no ALTZP flip), which
* -- fits KSEG.md's segment rules cleanly, and MAUXPLAY.SYSTEM
* -- had no flat headroom left for it (188 B over PMLI_IBF_BASE,
* -- measured by check-kernel-images) -- moving it, and its own
* -- 16-byte PDL_REC scratch (process.s), off the universal path
* -- entirely was the fix, not a trim of either.

*---------------------------------------------------------------
* OAPPEND-1 (docs/OAPPEND-1.md): the OPEN-time half of per-write
* O_APPEND. MOVED OUT of PRC_OPEN (procfile3.s) rather than
* added to it: the intent parse and the admission count are
* subroutines here, so procfile3.s got SMALLER.
*
* PRC_OPEN_INT -- the caller's param_count -> PRC_ROI, the
* OFT flag the new entry will carry: OPEN_RO ($83) = OFTF_RO,
* OPEN_APPEND ($23) = OFTF_AP, anything else 0 (a no-intent,
* write-capable open). EXACT matches only, so 3, a zero and an
* $A5-poisoned count stay no-intent. A match rewrites the count
* to 3: the MLI answers $04 to any other count. OPEN_RO_APP
* ($A3, read + append) contradicts itself and is RESERVED:
* refused ERR_INVAL, carry set, reported; nothing is opened.
*---------------------------------------------------------------
PRC_OPEN_INT
            ldx   #OFTF_RO
            lda   PRC_PARM
            cmp   #OPEN_RO
            beq   :set
            ldx   #OFTF_AP
            cmp   #OPEN_APPEND
            beq   :set
            ldx   #0
            cmp   #OPEN_RO_APP
            bne   :store
            lda   #ERR_INVAL
            jsr   PRC_FAIL_A
            sec
            rts
:set        lda   #3                ;the MLI count
            sta   PRC_PARM
:store      stx   PRC_ROI
            clc
            rts

*---------------------------------------------------------------
* PRC_ADMIT -- may this open JOIN the path's open entries? IN: X
* = the first matching OFT entry (PRC_FILE_FIND's), PRC_ROI =
* the incoming intent. OUT: carry CLEAR = join, SET = refuse
* ($50 is the caller's). Counts EVERY entry of the path,
* resident and parked (PRC_FIND_FROM walks them; slot order is
* not open order), in three classes: readers (OFTF_RO),
* appenders
* (OFTF_AP) and no-intent writers (neither).
*
*   incoming reader     joins iff NO no-intent writer, or
*                       exactly
*                       one and no appenders
*   incoming appender   joins iff NO no-intent writer
*   incoming no-intent  joins iff NO writer of either kind
*
* Mixed append + no-intent stays refused (A8): a no-intent
* writer's mark is its own and would be overwritten by the
* appenders' seeks. Clobbers A, X, Y, PRC_VICT (no-intent
* count), PRC_LENDX (appender count; the unpark that owns it
* cannot be in flight here).
*---------------------------------------------------------------
PRC_ADMIT
            stz   PRC_VICT
            stz   PRC_LENDX
:cnt        lda   OFT_PIPE,x
            bmi   :nxt
            and   #OFTF_AP
            beq   :nowr
            inc   PRC_LENDX
            bra   :nxt
:nowr       inc   PRC_VICT
:nxt        inx
            jsr   PRC_FIND_FROM
            bcs   :cnt
            lda   PRC_ROI
            bmi   :rd
            lda   PRC_VICT         ;appender: no-intent count
            ldx   PRC_ROI
            bne   :tst
            ora   PRC_LENDX        ;no-intent: any writer
            bra   :tst
:rd         lda   PRC_VICT         ;reader: one no-intent writer
            beq   :tst             ;is fine, if no appender
            dec   a
            ora   PRC_LENDX
:tst        cmp   #1               ;carry set = refuse
            rts
