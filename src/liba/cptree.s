*---------------------------------------------------------------
* cptree.s -- recursive directory copy, and recursive removal.
*
* The engine behind `mv SRC DST` with a DIRECTORY source across
* parents, and behind `cp -r`. Design note: docs/CPTREE.md.
* Task brief: docs/RECURSIVE-MV.md, docs/TASKS.md #16.
*
* WHY IT EXISTS. MLI RENAME cannot relink across directories at
* all (P8 TRM: pathname and new_pathname must "indicate files in
* the same directory"), so moving a directory to a different
* parent is a recursive COPY followed by a recursive DESTROY.
* Until 2026-08-25 `mv` refused that, which made `mv DIR1 DIR2`
* mean two different things depending on whether DIR2 happened
* to exist -- a rename when absent, a refusal when present,
* where every Unix moves DIR1 INTO DIR2. The trigger was the
* state of the volume, not the text of the command. That is
* avoidable semantic drift and this module is its removal.
*
* THE WALK is find.s's, not a new one: an iterative DFS with an
* EXPLICIT depth stack, because a 6502 has a 256-byte hardware
* stack and -- the sharper reason -- src/liba/readdir.s is a
* SINGLETON, so only one directory may be open at a time.
* Descending CLOSES the current directory; returning to a paused
* ancestor REOPENS it and replays READDIR past the entries it
* had already yielded (CPT_SKIP). See find.s's header for the
* full argument; this module inherits it wholesale, including
* CPT_MAXDEP and the "too long for any MLI call" fence.
*
* ONE FD AT A TIME, AND THAT IS A REQUIREMENT. This module
* CLOSES the directory before every file copy and every CREATE,
* then reopens and replays -- which costs a level with n entries
* O(n) re-reads of its own directory blocks. That is not
* fastidiousness. inc/mm.mlibuf.equ's MLI_IOBUF_CNT is
* 6, each open file costs a page-aligned 1024-byte kernel
* io_buffer, and those buffers are SYSTEM-WIDE, not per-process.
* That same file records a MEASURED high-water of 4 during
* check-shlang -- "outer sh's own script fd + its 2> capture
* file + a NESTED sh's script fd + the spawn loader's transient
* buffer" -- and records that at a ceiling of 4 the symptom was
* `cat: cannot open <path>` on a file that plainly exists. Every
* check-e2e-fs case runs as `MV ... > /mnt/MAUX/OUT/Onn 2>&1`
* under
* sh, so the pool is already partly spent before the walk
* starts. Holding the directory open across a file copy would
* want three fds of this module's own and push the system to 5
* of 6. Closing keeps the peak at 2 -- exactly what mv and cp
* cost today.
*
* IT ALSO MEANS NOTHING IS EVER DESTROYED WHILE ITS PARENT
* DIRECTORY IS OPEN. Whether that is safe on ProDOS is a
* question the commons does not answer (searched 2026-08-25:
* "DESTROY entry while directory is open", "modify directory
* during enumeration" -- nothing), so this design sidesteps it
* rather than betting on it.
*
* ERRORS ABORT; THEY DO NOT CONTINUE. `find` reports a bad entry
* and keeps walking. This module must not: a partial copy
* followed by a teardown loses data. The first failure of any
* kind closes the directory, records a reason in CPT_ERR and
* returns carry set with the source tree UNTOUCHED. That is what
* preserves mv.s's existing written guarantee ("SRC is unlinked
* only after a clean copy") at directory granularity, and it is
* also why the teardown is a SECOND PASS rather than interleaved
* with the copy.
*
* THE TEARDOWN NEEDS NO RESUME COUNTER. DESTROY refuses a
* NON-EMPTY subdirectory with $4E and succeeds on an empty one
* (learning:01M0T0YSPMJE238VH46CZPDR2V), so removal is
* deepest-child-first. CPT_RMTREE reopens the directory each
* iteration and always takes ENTRY ZERO: deleting IS the cursor.
* Every iteration either destroys an entry or descends one
* level, and descent is bounded by CPT_MAXDEP, so it terminates.
*
* NO EMITTED DATA. Every cell this module touches -- the eight
* MLI parmlists included -- lives in src/liba/libabss.s's dum
* arena and is stored by CPT_INIT. `mv` is TEXT_IMMUTABLE and
* check-textaudit measures it every sweep; a parmlist emitted
* into text is data the kernel writes results back into
* (check_purity write shape D) and would dirty mv's image on
* every run. That is the hazard that has already cost this
* project two bugs (learning:01M0T103ZQSAEGQ5D8FS8XZ8V4). See
* libabss.s's cptree section. Diagnostics are the CONSUMER's --
* this module returns a reason code and never prints.
*
* PUBLIC ENTRY POINTS
*
*  CPT_START   IN:  CPT_SRC/CPT_SLEN = source directory,
*                   CPT_DST/CPT_DLEN = destination directory,
*                   which the CALLER has already created.
*              OUT: carry clear = whole tree mirrored.
*                   carry set   = failed, CPT_ERR = reason.
*  CPT_RMTREE  IN:  CPT_SRC/CPT_SLEN = root to remove.
*              OUT: same contract. Removes the root itself.
*  CPT_MKDIR   CREATE CPT_DST as a subdirectory. $47 on an
*              existing DIRECTORY is success (that is cp -r's
*              merge); $47 on an existing FILE is a failure.
*  CPT_COPY1   Copy the one regular file CPT_SRC -> CPT_DST,
*              preserving file_type/aux_type.
*  CPT_ISDESC  IN: PTR0 = base, PTR1 = candidate (both liba
*              strings). OUT: carry SET if candidate IS base or
*              lies strictly beneath it. Guards the
*              move-into-itself case.
*  CPT_UNPATH  IN: A/X = an MLI-shaped path, PTR1 = destination.
*              Writes it back out as a liba string; A = length.
*              cp.s builds MLI paths up front and needs the
*              liba-string form this module walks in.
*
* CPT_ERR REASON CODES. A real MLI errno is always < $80, so the
* two maux-side refusals take values no MLI call can return and
* the consumer can tell them apart without a second flag.
*---------------------------------------------------------------
* -- CPTE_LONG/CPTE_DEEP moved to inc/cptree.equ: cp.s and
* -- mv.s `cmp` them above their `put` of this file.

* -- CPT_EDUP/CPT_STYPVOL moved to inc/cptree.equ
* -- (2026-09-01): the cptree2.s split made them cross-module
* -- references, and REL cannot export an equate
* -- (check-librel's rule; the 2026-08-29 moves are precedent).

* -- THE RECORD-STRIDE TRIPWIRE. libabss.s reserves CPT_REC as
* -- CPT_RECSZ bytes and must assemble without readdir.s (38 of
* -- the 40 programs link one and not the other), so the stride
* -- is spelled there rather than as RD_SIZE. This module links
* -- BOTH, so it is the one place the two spellings can be
* -- compared -- and `err` fails the assembly if they ever
* -- disagree, which a comment could not.
            err   RD_SIZE-CPT_RECSZ

*---------------------------------------------------------------
* CPT_INIT -- store every constant parmlist field. Called first
* by both public entry points; nothing here may legally run
* before one of them. CLOBBERS: A.
*---------------------------------------------------------------
CPT_INIT    lda   #PCOUNT_OPEN
            sta   CPT_OP
            sta   CPT_O2
            lda   #<CPT_MP
            sta   CPT_OP_PATH
            lda   #>CPT_MP
            sta   CPT_OP_PATH+1
            lda   #<CPT_MP2
            sta   CPT_O2_PATH
            lda   #>CPT_MP2
            sta   CPT_O2_PATH+1
*-- io_buffer is a documented DON'T-CARE: the kernel repoints it
*-- at its own allocated buffer before issuing the real MLI call
*-- (src/kernel/procfile3.s PRC_OPEN) and never copies the field
*-- back. Stored anyway -- an uncleared dum cell handed to a
*-- syscall is a cell nobody wrote, and "the kernel ignores it"
*-- is a fact about today's kernel.
            stz   CPT_OP_IOB
            stz   CPT_OP_IOB+1
            stz   CPT_O2_IOB
            stz   CPT_O2_IOB+1
            lda   #PCOUNT_CREATE
            sta   CPT_CR
            lda   #<CPT_MP2
            sta   CPT_CR_PATH
            lda   #>CPT_MP2
            sta   CPT_CR_PATH+1
            lda   #ACCESS_UNLKD
            sta   CPT_CR_ACC
*-- dates stay zero: no clock is wired and SET_FILE_INFO is not
*-- exposed (docs/USERLAND.md "ABI RESOLUTIONS", task #11).
            stz   CPT_CR_DATE
            stz   CPT_CR_DATE+1
            stz   CPT_CR_TIME
            stz   CPT_CR_TIME+1
            lda   #PCOUNT_GFI
            sta   CPT_GF
            lda   #PCOUNT_READ
            sta   CPT_RP
            lda   #PCOUNT_WRITE
            sta   CPT_WP
            lda   #<CPT_BUF
            sta   CPT_RP_BUF
            sta   CPT_WP_BUF
            lda   #>CPT_BUF
            sta   CPT_RP_BUF+1
            sta   CPT_WP_BUF+1
            lda   #<CPT_BUFSZ
            sta   CPT_RP_REQ
            lda   #>CPT_BUFSZ
            sta   CPT_RP_REQ+1
            lda   #PCOUNT_CLOSE
            sta   CPT_CL
            lda   #PCNT_DESTROY
            sta   CPT_DP
            stz   CPT_ERR
            rts

*---------------------------------------------------------------
* CPT_MKS / CPT_MKD -- rebuild the MLI-shaped path for the
* current source / destination. Run fresh before every MLI call
* rather than cached: the walk mutates CPT_SRC/CPT_DST
* constantly, and a stale MLI path is the shape of bug that
* opens one file and destroys another. CLOBBERS: A, Y, PTR0,
* PTR1, PTR2. PRESERVES: X (MKPATH's own contract).
*---------------------------------------------------------------
CPT_MKS     lda   #<CPT_SRC
            sta   PTR0
            lda   #>CPT_SRC
            sta   PTR0+1
            lda   #<CPT_MP
            sta   PTR1
            lda   #>CPT_MP
            sta   PTR1+1
            jmp   MKPATH

CPT_MKD     lda   #<CPT_DST
            sta   PTR0
            lda   #>CPT_DST
            sta   PTR0+1
            lda   #<CPT_MP2
            sta   PTR1
            lda   #>CPT_MP2
            sta   PTR1+1
            jmp   MKPATH

*---------------------------------------------------------------
* CPT_OPENS -- MKPATH the current source, then OPENDIR it.
* OUT: carry/A straight through from OPENDIR.
*---------------------------------------------------------------
CPT_OPENS   jsr   CPT_MKS
            lda   #<CPT_MP
            ldx   #>CPT_MP
            jmp   OPENDIR

*---------------------------------------------------------------
* CPT_APPEND -- append "/" + CPT_REC's name to the liba string
* at PTR1, whose current length is CPT_ALEN.
* OUT: carry clear = it fits an MLI pathname, CPT_ALEN updated.
*      carry set   = the result would exceed MLI_PTH_MAXLN; the
*                    buffer may hold a partial write, which is
*                    why every caller aborts rather than
*                    continuing (a truncated pathname can name a
*                    real, DIFFERENT, shorter object -- measured
*                    on hardware, src/liba/mli.s's header).
* The buffer is CPT_PBUF bytes, the writers' own worst case, so
* the partial write cannot overrun. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
CPT_APPEND  ldy   CPT_ALEN
            cpy   #MLI_PTH_MAXLN
            bcs   :toolong            ;no room for '/' + a char
            lda   #"/"
            sta   (PTR1),y
            iny
            ldx   #0
:cp         lda   CPT_REC+RD_NAME,x
            beq   :done
            cpy   #MLI_PTH_MAXLN
            bcs   :toolong
            sta   (PTR1),y
            iny
            inx
            bne   :cp
:done       lda   #0
            sta   (PTR1),y
            sty   CPT_ALEN
            clc
            rts
:toolong    sec
            rts

*---------------------------------------------------------------
* CPT_APPBOTH -- append the current entry's name to BOTH paths,
* saving the pre-append lengths in CPT_OSL/CPT_ODL so the caller
* can undo it. OUT: carry set = too long (CPT_ERR set).
* CLOBBERS: A, X, Y, PTR1.
*---------------------------------------------------------------
CPT_APPBOTH lda   CPT_SLEN
            sta   CPT_OSL
            lda   CPT_DLEN
            sta   CPT_ODL
            lda   #<CPT_SRC
            sta   PTR1
            lda   #>CPT_SRC
            sta   PTR1+1
            lda   CPT_SLEN
            sta   CPT_ALEN
            jsr   CPT_APPEND
            bcs   :long
            lda   CPT_ALEN
            sta   CPT_SLEN
            lda   #<CPT_DST
            sta   PTR1
            lda   #>CPT_DST
            sta   PTR1+1
            lda   CPT_DLEN
            sta   CPT_ALEN
            jsr   CPT_APPEND
            bcs   :long
            lda   CPT_ALEN
            sta   CPT_DLEN
            clc
            rts
:long       lda   #CPTE_LONG
            sta   CPT_ERR
            sec
            rts

*---------------------------------------------------------------
* CPT_UNAPP -- undo CPT_APPBOTH: restore both lengths and
* re-terminate both buffers. RE-TERMINATING IS NOT OPTIONAL --
* MKPATH reads to the string's own NUL, not to a length, so
* leaving the deeper terminator in place would rebuild the CHILD
* path on the next call. find.s's POPFRAME carries the same note
* for the same reason. CLOBBERS: A, X.
*---------------------------------------------------------------
CPT_UNAPP   lda   CPT_OSL
            sta   CPT_SLEN
            tax
            stz   CPT_SRC,x
            lda   CPT_ODL
            sta   CPT_DLEN
            tax
            stz   CPT_DST,x
            rts

*---------------------------------------------------------------
* CPT_PUSH -- save the PARENT's two path lengths and its resume
* count (this entry included, hence the +1) into slot CPT_DEPTH.
* CLOBBERS: A, X.
*---------------------------------------------------------------
CPT_PUSH    ldx   CPT_DEPTH
            lda   CPT_OSL
            sta   CPT_STKS,x
            lda   CPT_ODL
            sta   CPT_STKD,x
            txa
            asl   a
            tax
            lda   CPT_RESN
            clc
            adc   #1
            sta   CPT_STKR,x
            lda   CPT_RESN+1
            adc   #0
            sta   CPT_STKR+1,x
            rts

*---------------------------------------------------------------
* CPT_POP -- CPT_DEPTH--, restore both lengths and the resume
* count, and re-terminate both buffers at the restored lengths
* (see CPT_UNAPP for why). CLOBBERS: A, X.
*---------------------------------------------------------------
CPT_POP     dec   CPT_DEPTH
            ldx   CPT_DEPTH
            lda   CPT_STKS,x
            sta   CPT_SLEN
            lda   CPT_STKD,x
            sta   CPT_DLEN
            txa
            asl   a
            tax
            lda   CPT_STKR,x
            sta   CPT_RESN
            lda   CPT_STKR+1,x
            sta   CPT_RESN+1
            ldx   CPT_SLEN
            stz   CPT_SRC,x
            ldx   CPT_DLEN
            stz   CPT_DST,x
            rts

*---------------------------------------------------------------
* CPT_SKIP -- call READDIR CPT_RESN times, discarding the
* results, to fast-forward a freshly reopened directory back to
* where a descend paused it. COUNTS DOWN A COPY -- see
* cptreebss.s's note on CPT_SKIPN, and find.s's SKIPRESUME for
* the loop this would otherwise be.
*---------------------------------------------------------------
CPT_SKIP    lda   CPT_RESN
            sta   CPT_SKIPN
            lda   CPT_RESN+1
            sta   CPT_SKIPN+1
            ora   CPT_SKIPN
            beq   :done
:loop       lda   #<CPT_REC
            ldx   #>CPT_REC
            jsr   READDIR
            bcs   :done              ;cannot happen -- defensive
            lda   CPT_SKIPN
            bne   :dec
            dec   CPT_SKIPN+1
:dec        dec   CPT_SKIPN
            lda   CPT_SKIPN
            ora   CPT_SKIPN+1
            bne   :loop
:done       rts

*---------------------------------------------------------------
* CPT_START -- mirror the tree under CPT_SRC into CPT_DST, which
* the caller has already created. See the file header.
*---------------------------------------------------------------
CPT_START   jsr   CPT_INIT
            stz   CPT_DEPTH
            stz   CPT_RESN
            stz   CPT_RESN+1
            jsr   CPT_OPENS
            bcc   CPT_LOOP
            sta   CPT_ERR
            sec
            rts

*-- Invariant at the top of the loop: the CURRENT level's
*-- directory IS open, and every ancestor is closed.
CPT_LOOP    lda   #<CPT_REC
            ldx   #>CPT_REC
            jsr   READDIR
            bcc   :haveent
            cmp   #0
            bne   :rderr
*-- Level exhausted. Close it, and either finish or resume the
*-- parent where it paused.
            jsr   CLOSEDIR
            lda   CPT_DEPTH
            bne   :pop
            clc
            rts
:pop        jsr   CPT_POP
            jsr   CPT_OPENS
            bcs   :operr
            jsr   CPT_SKIP
            jmp   CPT_LOOP
:rderr      sta   CPT_ERR
            jsr   CLOSEDIR
            sec
            rts
:operr      sta   CPT_ERR
            sec
            rts

:haveent    jsr   CPT_APPBOTH
            bcc   :fits
            jsr   CLOSEDIR            ;CPT_ERR already CPTE_LONG
            sec
            rts
:fits       ldy   #RD_STYPE
            lda   CPT_REC,y
            cmp   #STYP_DIR
            beq   :isdir
            cmp   #CPT_STYPVOL
            beq   :isdir

*-- A PLAIN FILE. Close the directory first: one fd at a time
*-- (see the header), and the copy needs two of its own.
            jsr   CLOSEDIR
            jsr   CPT_COPY1
            bcs   :failed
            jsr   CPT_UNAPP
            inc   CPT_RESN
            bne   :reopen
            inc   CPT_RESN+1
:reopen     jsr   CPT_OPENS
            bcs   :operr
            jsr   CPT_SKIP
            jmp   CPT_LOOP
:failed     sec                       ;CPT_ERR set by CPT_COPY1
            rts

*-- A SUBDIRECTORY. Create its mirror, then descend.
:isdir      jsr   CLOSEDIR
            lda   CPT_DEPTH
            cmp   #CPT_MAXDEP
            bcs   :toodeep
            jsr   CPT_MKDIR
            bcs   :failed
            jsr   CPT_PUSH
            stz   CPT_RESN
            stz   CPT_RESN+1
            inc   CPT_DEPTH
            jsr   CPT_OPENS
            bcs   :operr
            jmp   CPT_LOOP
:toodeep    lda   #CPTE_DEEP
            sta   CPT_ERR
            sec
            rts
