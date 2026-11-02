*---------------------------------------------------------------
* procspawn3.s -- the file-backed image loader and its helpers.
*
* SPLIT OUT OF procspawn.s (S9 L4, 2026-08-29): that file's own
* stripped text was 13713 B, past `as`'s 16126 B source window,
* so
* it could never be assembled inside maux as one REL module. The
* cut is at a section boundary and this file is `put`
* immediately
* after its parent, so the emitted bytes are unchanged -- which
* is
* what check-bytes asserts.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PRC_CHK_BASE -- OUT: carry CLEAR if PRC_LOADADR is a base this
* kernel can load at, carry SET if it must be refused.
*
* THE FLOOR IS LOAD_BASE ($0800) AND IT IS NOT COSMETIC: argv
* and envp strings are packed at PRC_ARGV_STR ($0300) and
* ARG_MAX is literally `LOAD_BASE-PRC_ARGV_STR`, so an image
* claiming a lower base loads straight over the arguments it is
* about to be handed -- and lower still is the stack and the
* zero page. The ceiling is PRC_BRK_LIM: at or above it there is
* no process window left to load into.
*
* The floor drops the day args-above-image lands (S9-PLAN L3b);
* until then, a binary that wants a lower base is a bug in
* whatever linked it, and refusing it loudly beats loading it
* over the argv window and crashing somewhere else.
*---------------------------------------------------------------
PRC_CHK_BASE
            lda   PRC_LOADADR+1
            cmp   #>LOAD_BASE
            bcc   :bad
            cmp   #>PRC_BRK_LIM
            bcs   :bad
            clc
            rts
:bad        sec
            rts

* -- PRC_PATHBUF already holds the canonical spawn pathname:
* -- PRC_SPAWN copies it BEFORE allocating the bank now, because
* -- the allocator is what decides whether this is a warm
* -- respawn (docs/STICKY.md sec 25). LZ_WARM says it was: the
* -- child's bank already holds this program's text at
* -- LOAD_BASE, PRC_IMAGE_LEN came from the tag, and there is
* -- nothing to open, read or copy -- only sec 21's zeroed page,
* -- whose BankCopyZ `stz K_BC_ERR` is this path's success
* -- return.
PRC_LD_FL_IMG
            stz   K_BC_ERR
            lda   LZ_WARM
            beq   :cold
            jmp   PRC_ZERO_PG

*-- S9 L3b: HONOUR THE BIN AUX TYPE. GET_FILE_INFO on the same
*-- canonical pathname the OPEN below uses, purely for the
*-- aux_type -- there is no MLI call that hands back aux for an
*-- already-open refnum, so this is a second directory walk, and
*-- it is bought for the one thing the open cannot tell us.
*-- (The WARM path does not repeat it: LZ_TRY_WARM already made
*-- this exact call to test freshness and parks the answer in
*-- PRC_LOADADR itself.)
*--
*-- Placed BEFORE PRC_ALLC_IBF deliberately: a failure here has
*-- nothing to unwind.
:cold       lda   #<PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHHI
            jsr   PMLI_GFI_CALL
            beq   :gfiok
*-- cannot read the metadata: let the OPEN below report the real
*-- error, and load at the floor as every image did before L3b
            lda   #<LOAD_BASE
            sta   PRC_LOADADR
            lda   #>LOAD_BASE
            sta   PRC_LOADADR+1
            bra   :basedone
:gfiok      lda   PML_GFI_PARMS+MLI_GFI_ACC+1 ;file_type: BIN or
            inc   a                     ;SYS only ($06 -> 7,
            beq   :ftok                 ;$FF -> 0); inspection,
            cmp   #7                    ;no exec bit
            bne   :noexec
:ftok
            lda   PML_GFI_PARMS+MLI_GFI_ATYPE
            sta   PRC_LOADADR
            lda   PML_GFI_PARMS+MLI_GFI_ATYPE+1
            sta   PRC_LOADADR+1
            jsr   PRC_CHK_BASE
            bcc   :basedone
            lda   #ERR_INVAL
:failA      jsr   PRC_FAIL_A
            lda   #1
            sta   K_BC_ERR
            rts
:noexec     lda   #ERR_NOEXEC
            bra   :failA
:basedone   jsr   PRC_ALLC_IBF
            bcc   :bufok
            lda   #1
            sta   K_BC_ERR
            rts
:bufok      sta   PRC_IOBUF_ID
            lda   #0
            sta   PML_OPN_PARMS+MLI_IOBUFLO
            lda   PRC_IOBUF_ID
            jsr   PRC_IBF_HI_A
            sta   PML_OPN_PARMS+MLI_IOBUFHI
            jsr   PMLI_OPN_CALL
            beq   :openok
            pha
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            pla
            jsr   PRC_FAIL_A
            lda   #1
            sta   K_BC_ERR
            rts

:openok     lda   PML_OPN_PARMS+MLI_OPEN_REF
            sta   PML_GTF_PARMS+MLI_REF
            sta   PMLI_RD_PARMS+MLI_REF
            jsr   PMLI_GTF_CALL
            bne   :readerr               ;A = the MLI error
            lda   PML_GTF_PARMS+MLI_EOFBANK
            beq   :small
*-- An image that will not fit a 64K bank is a property of the
*-- FILE, not of the machine's memory: nothing about it is
*-- transient and no number of free banks would help. It used to
*-- answer ERR_NOMEM, which sh could not tell from genuine bank
*-- exhaustion -- harmless only while sh reported every refusal
*-- as `command not found`, and a lie the moment it learned to
*-- say `no more processes` (a 68 KB file reported a full
*-- process table on a machine with 14 banks free). So it joins
*-- the other two refusals this loader decides by inspection,
*-- a wrong file type and an empty file: ERR_NOEXEC, found but
*-- not executable, $? 126, which is what POSIX asks for too.
            lda   #ERR_NOEXEC
            bra   :readerr
*-- KFIX2 1: an EMPTY file is not a program. The loader used to
*-- copy nothing and run whatever the bank held at the load base
*-- -- zeros on a fresh bank -- and a user BRK ($00) parked the
*-- WHOLE machine in KRN_BRK_TRAP, so `true > X ; ./X` killed
*-- the console. (Since KBRK a user BRK kills just the process,
*-- $? 133; the refusal stays: an empty file is not a program.)
*-- The same refusal a non-executable file gets (ERR_NOEXEC, sh:
*-- cannot execute, $? 126), through the shared close-and-fail
*-- tail.
:small      lda   PML_GTF_PARMS+MLI_EOFLO
            sta   PRC_REMAIN
            sta   PRC_IMAGE_LEN
            lda   PML_GTF_PARMS+MLI_EOFHI
            sta   PRC_REMAIN+1
            sta   PRC_IMAGE_LEN+1
            ora   PRC_REMAIN
            bne   :sized
            lda   #ERR_NOEXEC
            bra   :readerr
:sized      lda   PRC_LOADADR
            sta   PRC_USER_PTR
            lda   PRC_LOADADR+1
            sta   PRC_USER_PTR+1
            stz   PRC_DONE
            stz   PRC_DONE+1

* -- length is known, the read has not started -- the latest
* -- possible point to read mtime "before" the load
* -- (docs/STICKY.md sec 4). LZ_BEGIN is a no-op-on-failure: it
* -- never touches K_BC_ERR, so failing to stamp a tag can
* -- never fail the real spawn.
            jsr   LZ_BEGIN

:rdloop     lda   PRC_REMAIN
            ora   PRC_REMAIN+1
            bne   :more
            jmp   :done
:more
            jsr   PRC_PCK_CHUNK
            lda   #<PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFLO
            lda   #>PMLI_XFER_BUF
            sta   PMLI_RD_PARMS+MLI_BUFHI
* -- K1: PRC_CHUNK is now 2 bytes (max 512, was 1 byte/128) --
* -- REQHI comes from PRC_CHUNK+1, not a hardcoded stz.
            lda   PRC_CHUNK
            sta   PMLI_RD_PARMS+MLI_REQLO
            lda   PRC_CHUNK+1
            sta   PMLI_RD_PARMS+MLI_REQHI
            stz   PMLI_RD_PARMS+MLI_TRANSLO
            stz   PMLI_RD_PARMS+MLI_TRANSHI
            jsr   PMLI_RD_CALL
            beq   :readok
            cmp   #MLI_ERR_EOF
            bne   :readerr
            jmp   :done
:readerr
            pha
            lda   PML_OPN_PARMS+MLI_OPEN_REF
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            pla
            jsr   PRC_FAIL_A
            lda   #1
            sta   K_BC_ERR
            rts
:readok     lda   PMLI_RD_PARMS+MLI_TRANSLO
            ora   PMLI_RD_PARMS+MLI_TRANSHI
            bne   :hasbytes
            jmp   :done
:hasbytes
            lda   #BC_KIND_MAIN
            sta   K_BC_SRCKIND
            lda   #<PMLI_XFER_BUF
            sta   K_BC_SRCADDR
            lda   #>PMLI_XFER_BUF
            sta   K_BC_SRCADDR+1
            stz   K_BC_SRCBANK
            lda   #BC_KIND_BANK
            sta   K_BC_DSTKIND
            lda   PRC_USER_PTR
            sta   K_BC_DSTADDR
            lda   PRC_USER_PTR+1
            sta   K_BC_DSTADDR+1
            lda   PRC_CHLD_BANK
            sta   K_BC_DSTBANK
            lda   PMLI_RD_PARMS+MLI_TRANSLO
            sta   K_BC_LEN
            lda   PMLI_RD_PARMS+MLI_TRANSHI
            sta   K_BC_LEN+1
            jsr   BankCopy
            lda   K_BC_ERR
            beq   :copied
            lda   PML_OPN_PARMS+MLI_OPEN_REF
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
            rts
:copied
* -- NO SECOND COPY. The sec 2-5 cache staged every chunk a
* -- second time into a cache bank; lazy free deletes that
* -- outright -- the cold path's one copy into the child bank
* -- IS the population, because the bank is simply never given
* -- back (docs/STICKY.md sec 25).
            jsr   PADV_FL_PTRS
            jmp   :rdloop

:done       lda   PML_OPN_PARMS+MLI_OPEN_REF
            jsr   PCLS_RAWREF_A
            lda   PRC_IOBUF_ID
            jsr   PRC_FR_IBF_A
* -- tags the child's bank with this program ONLY on this normal
* -- completion path -- every error exit above `rts`s directly,
* -- so a partial load can never leave a tag behind
* -- (docs/STICKY.md sec 25).
            jsr   LZ_COMMIT
            jmp   PRC_ZERO_PG            ;sec 21's page, and its
                                         ;`stz K_BC_ERR` is this
                                         ;path's success return

*-- THE BANK NUMBER TRAVELS IN X, NOT IN P_BANK, and that is a
*-- FIX (2026-08-27) rather than a style choice. P_BANK is ZERO
*-- PAGE ($DB, process.s) and `sta ALTZPAUX` two lines below
*-- swaps the zero page for the CHILD's -- so the old
*-- `lda P_BANK` here read the child bank's uninitialised $DB,
*-- not the value stored on entry, and stamped BANK_ID with
*-- whatever that was. On a fresh bank it is 0, so every bank
*-- has been claiming to be bank 0 since this routine was
*-- written. It went unnoticed because NOTHING EVER READ
*-- BANK_ID -- the byte exists so a bank can identify itself
*-- ($C073 being write-only) and sh's `$$` is its first reader.
*-- Same shape as CWD_READ's wrong-bank defect: latent for
*-- months because the garbage happened to be zeros.
*-- X is untouched by the copy loop, so it costs nothing.
PRC_STMP_BANK
            sta   P_BANK
            tax
            sta   BANKSEL
            lda   LCBANK2_RAM
            lda   LCBANK2_RAM
            sta   ALTZPAUX
            ldy   #0
:cp         lda   FFP_SYSC_ENT,y
            sta   $FF00,y
            iny
            bne   :cp
            txa
            sta   BANK_ID
            sta   ALTZPMAIN
            rts

PRC_SYNTH_FRM
            sta   BANKSEL
            sta   ALTZPAUX
            lda   #0
            sta   $01FA
            sta   $01FB
            sta   $01FC
            lda   #$20
            sta   $01FD
            lda   #<LOAD_BASE
            sta   $01FE
            lda   #>LOAD_BASE
            sta   $01FF
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* PRC_GFI_PATH -- GET_FILE_INFO on PRC_PATHBUF, the canonical
* spawn pathname. Leaves Z exactly as PMLI_GFI_CALL does.
* Factored because L3b's cold-path aux read is the same six
* lines LZ_TRY_WARM already used for its freshness test, and
* this kernel has no bytes to spare.
*---------------------------------------------------------------
PRC_GFI_PATH
            lda   #<PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHLO
            lda   #>PRC_PATHBUF
            sta   PML_GFI_PARMS+MLI_PATHHI
            jmp   PMLI_GFI_CALL

*---------------------------------------------------------------
* PRC_SET_ENTRY -- IN: A = the child's bank. Repoints the frame
* PRC_SYNTH_FRM just built at PRC_LOADADR, the address the image
* was actually loaded at (S9 L3b).
*
* A SEPARATE ROUTINE, NOT A PARAMETER TO PRC_SYNTH_FRM, and not
* PRC_SYNTH_FRM moved below the load. That routine's contract is
* "launch at LOAD_BASE" and THIRTY-ONE TEST HARNESSES call it
* directly to start their own parent process -- src/test/*b.s,
* none of them through PRC_SPAWN. Making it read PRC_LOADADR
* broke every one of them at once: the cell is still zero when a
* harness launches its parent, so the RTI went to $0000 and ran
* the zero page as BRK opcodes into KRN_BRK_TRAP's `_hang` --
* the harness PARENT is pid 1, root tier: a BRK still parks it.
* check-fileprocess did NOT catch it -- fileproctestb.s
* follows the call with its own PATCH_PAR_FRM and overwrites the
* address anyway -- while check-fork and check-process, which
* take the default, hung. Same bytes, opposite verdicts.
*---------------------------------------------------------------
PRC_SET_ENTRY
            sta   BANKSEL
            sta   ALTZPAUX
            lda   PRC_LOADADR
            sta   $01FE
            lda   PRC_LOADADR+1
            sta   $01FF
            sta   ALTZPMAIN
            rts

*---------------------------------------------------------------
* PSTG_ARGV -- task #13 general argc/argv packer
* (code review C4; replaces the old two-entry
* "argv[0]+argv[1]" bootstrap bridge). Implements
* docs/SYSCALL.md ruling 13 in full: PRC_PARM+2/+3 is the
* PARENT's pointer to a NULL-terminated array of 2-byte
* pointers, each pointing at a NUL-terminated liba string in the
* PARENT's own memory (ordinary argv, Unix convention --
* argv[argc] == NULL). This routine re-packs the STRING BYTES
* (never the parent's raw pointer VALUES, which are meaningless
* in the child's own address space) into the child's
* PRC_ARGV_STR ($0300+) region, back-to-back NUL-terminated,
* and writes a fresh ARGC-then-pointer-array header at
* PRC_ARGV_HDR ($0200, inc/startup.equ's own convention)
* with each pointer RECOMPUTED to address the child's own copy.
*
* A NULL argv pointer (PRC_PARM+2/+3 both zero) means "no argv
* at all" -- ARGC=0, not even argv[0] -- preserved for the raw
* spawn() bootstrap images (processtest.s's E/R/W test images)
* that predate argv entirely and never pass one.
*
* LIMITS: two ceilings, BOTH derived from the memory map in
* inc/memmap.equ, neither one a declared count --
*   ARG_MAX      bytes of packed strings (PRC_ARGV_STR up to the
*                load base), accumulated in PRC_ARGOFF;
*   ARGV_PTR_LIM bytes of pointer array (PRC_ARGV_PTRS up to the
*                strings), which is what bounds the entry count.
* Exceeding either FAILS the spawn with ERR_2BIG (carry set on
* return). It does NOT truncate. The old code stopped staging at
* ARGV_MAX_CNT=16 entries and returned success, so a caller that
* passed more got a silently short argv -- `rm *` deleting some
* of what you asked for, one layer below where sh's own "too
* many arguments" check could see it (docs/LIMITS.md,
* learning:01M07V2D0T25FYD6ASCMPJYNWQ). The per-arg 64-byte
* PRC_ARGBUF cap is gone with it: it double-counted the same
* resource, and it silently cut a 64-character ProDOS path (the
* MLI's own MLI_PTH_MAXLN) down to 63.
*
* Strings are copied parent-bank -> child-bank by BankCopy, the
* house primitive, instead of the hand-rolled RAMWRTAUX stores
* this routine used to do. That is not only tidier: the string
* region now legitimately extends past $03FF, and BankCopy is
* what brackets CLR80STORE around a bank write. With 80STORE
* set, RAMRD/RAMWRT are IGNORED for $0400-$07FF and PAGE2 alone
* routes it (learning:01KW1GTYHGXMBZNR6DMQB2F712), so a
* hand-rolled write of a long argv would have landed in the
* motherboard text page instead of the child. 80STORE off is the
* kernel's documented steady state, which is exactly why this
* would have been a rare, mystifying failure rather than an
* obvious one.
*
* THE ENVIRONMENT SHARES THIS BLOCK (docs/SYSCALL.md item 13c,
* 2026-08-22). PRC_PARM+6/+7 is the parent's envp -- the same
* shape as argv, a NULL-terminated array of pointers to
* NUL-terminated "NAME=VALUE" strings -- and it is staged by the
* SAME loop into the SAME two regions, right after argv's:
*
*   $0200  argc                    1 byte
*   $0201  argv pointer array      argc*2
*          envc                    1 byte
*          envp pointer array      envc*2
*   $0300  packed strings -- argv's THEN envp's
*
* so ARG_MAX and ARGV_PTR_LIM are now COMBINED budgets (one
* PRC_ARGOFF, one PRC_PTROFF, both running across both passes).
* The ERR_2BIG contract extends unchanged to the pair: a program
* that started at all can trust that its argv AND its
* environment are complete, which is why the limit is checked
* here and not in sh.
*
* Returns: carry CLEAR = staged; carry SET = failed, with
* K_RESULT/K_RESULT_ERR already set by PRC_FAIL_A (PRC_SPAWN
* frees the child's bank and returns the error to the caller).
*---------------------------------------------------------------
PSTG_ARGV
            jsr   PRC_SEL_CRBNK           ;parent's bank, as a
            sta   PRC_PAR_BANK            ;NUMBER, in A (the
                                          ;K_CURBANK shadow --
                                          ;no scratch cell to
                                          ;race for any more)

            stz   PRC_ARGOFF            ;running child-side
                                         ;string-write
            stz   PRC_ARGOFF+1          ;offset from
                                         ;PRC_ARGV_STR, 16-bit
            stz   PRC_PTROFF            ;running pointer-array
                                         ;offset from
                                         ;PRC_ARGV_PTRS

            lda   PRC_PARM+2             ;the parent's argv
            sta   PRC_LISTP
            lda   PRC_PARM+3
            sta   PRC_LISTP+1
            jsr   PSTG_LIST
            bcs   :failed

            ;-- ARGC into the child. One byte, through the same
            ;-- primitive as everything else here. --
            lda   P_COUNT
            sta   PRC_ARGWORD
            lda   #<PRC_ARGV_HDR
            sta   K_BC_DSTADDR
            lda   #>PRC_ARGV_HDR
            sta   K_BC_DSTADDR+1
            lda   #1
            jsr   PSTG_TO_CHILD
            bcs   :failed
            jmp   PSTG_ENV                ;its rts is this
                                          ;routine's verdict
:failed     rts

*---------------------------------------------------------------
* PSTG_LIST -- stage ONE NULL-terminated parent pointer array
* (argv's, then envp's) into the child, appending its strings at
* PRC_ARGV_STR+PRC_ARGOFF and its pointers at
* PRC_ARGV_PTRS+PRC_PTROFF, both accumulators running ACROSS the
* two calls (item 13c's shared budgets).
*
* IN:  PRC_LISTP = the parent's array (0 = none at all)
* OUT: carry CLEAR + P_COUNT = entries staged; carry SET =
*      failed, already reported.
*
* A NULL PRC_LISTP means "no list" -- count 0, not even entry 0.
* For argv that is the raw spawn() bootstrap images
* (processtest.s's E/R/W images) that predate argv entirely; for
* envp it is every caller that predates the environment.
*---------------------------------------------------------------
PSTG_LIST   stz   P_COUNT                ;running entry index --
                                         ;becomes the count once
                                         ;the loop ends
            lda   PRC_LISTP
            ora   PRC_LISTP+1
            beq   :listdone

:loop       ;-- &list[P_COUNT] in the parent = base + 2*P_COUNT.
            ;-- P_COUNT can reach 127 here (reading the NULL
            ;-- terminator of a full 127-entry argv) but never
            ;-- 128, because the staging check below refuses
            ;-- the entry that would need pointer byte 254 --
            ;-- so this ASL never shifts a bit out.
            lda   P_COUNT
            asl   a
            clc
            adc   PRC_LISTP
            sta   P_PTR1
            lda   PRC_LISTP+1
            adc   #0
            sta   P_PTR1+1

            ;-- read list[P_COUNT] (2 bytes) from the PARENT's
            ;memory via
            ;-- PRDPAR_BYTE, the same idiom every other
            ;parent-memory read
            ;-- in this file uses (it re-selects the parent
            ;BANKSEL
            ;-- via PRC_SEL_CRBNK on every call -- K_CURPID is
            ;still the
            ;-- SPAWNING PARENT throughout PRC_SPAWN, the child
            ;isn't
            ;-- scheduled until SCH_CREATE runs, after this
            ;routine) --
            jsr   PRDPAR_BYTE
            bcs   :failed
            lda   PRC_BYTE
            sta   PRC_ARGV
            inc   P_PTR1
            bne   :hiok
            inc   P_PTR1+1
:hiok       jsr   PRDPAR_BYTE
            bcs   :failed
            lda   PRC_BYTE
            sta   PRC_ARGV+1
            lda   PRC_ARGV
            ora   PRC_ARGV+1
            beq   :listdone               ;NULL entry -- Unix
                                          ;argv[argc]== NULL
                                          ;terminator (ruling
                                          ;13)

            ;-- room for this POINTER? It occupies bytes
            ;-- PRC_PTROFF and PRC_PTROFF+1, and the array holds
            ;-- ARGV_PTR_LIM bytes (0..254) before the strings
            ;-- begin -- so an offset of 254 is one entry too
            ;-- far, and 127 entries is the ceiling the map
            ;-- implies for argv ALONE (envc and envp's own
            ;-- pointers come out of the same 255). Checked
            ;-- AFTER the NULL test on purpose: a FULL argv
            ;-- still has to READ its terminator without being
            ;-- refused for it. --
            lda   PRC_PTROFF
            cmp   #ARGV_PTR_LIM-1
            bcs   :toobig

            jsr   PMEAS_ARG               ;length + budget check
            bcs   :failed                 ;in the parent, before
                                          ;the child is touched

            jsr   PSTG_ONE_ARG            ;string bytes +
            bcs   :failed                 ;recomputed pointer

            inc   P_COUNT
            bra   :loop

:listdone   clc
            rts

:toobig     lda   #ERR_2BIG
            jsr   PRC_FAIL_A
            sec
:failed     rts

*---------------------------------------------------------------
* PMEAS_ARG -- measure the arg at PRC_ARGV (in the PARENT's
* memory) into PRC_ARGLEN, NUL included, enforcing ARG_MAX as it
* goes. There is no per-arg cap: an argument may be as long as
* the remaining budget allows, and the budget is the only thing
* that says no.
*
* The check is made BEFORE each read, against the running total
* PRC_ARGOFF+PRC_ARGLEN, so an arg that would overrun stops at
* the ceiling instead of scanning on -- which also makes an
* UNTERMINATED string in the parent a clean ERR_2BIG rather than
* a runaway loop through the parent's whole bank.
*
* Returns: carry CLEAR + PRC_ARGLEN; carry SET = failed
* (ERR_2BIG here, or PRDPAR_BYTE's own ERR_INVAL if the parent
* handed us an address copyin refuses).
*---------------------------------------------------------------
