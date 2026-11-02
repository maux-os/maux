*---------------------------------------------------------------
* cptree2.s -- cptree.s's second half: the recursive TEARDOWN
* (CPT_RMTREE), CPT_MKDIR/CPT_COPY1/CPT_ISDESC/CPT_UNPATH and
* the stat helpers. Split from cptree.s 2026-09-01 at the
* CPT_RMTREE global boundary for as's 16128-byte source window
* (check_dialect hazard 3b): the un-split file was 14,024
* stripped bytes -- alone nearly the whole window -- and rm
* joining cp/mv as a third consumer made it a NEW over-window
* unit, which the ratchet refuses. One assembly stream: every
* consumer puts this file IMMEDIATELY after cptree.s, and every
* rule in cptree.s's header applies unchanged.
*---------------------------------------------------------------

*---------------------------------------------------------------
* CPT_RMTREE -- remove CPT_SRC and everything under it, deepest
* child first. Reopens the directory every iteration and always
* takes ENTRY ZERO, so deleting IS the cursor and there is
* nothing to resume; nothing is destroyed while its parent is
* open. See the file header.
*---------------------------------------------------------------
CPT_RMTREE  jsr   CPT_INIT
            stz   CPT_DEPTH
CPT_RMLOOP  jsr   CPT_OPENS
            bcs   :operr
            lda   #<CPT_REC
            ldx   #>CPT_REC
            jsr   READDIR
*-- CLOSEDIR runs SC_CLOSE, which returns its own carry and A.
*-- Preserve READDIR's verdict across it.
            php
            pha
            jsr   CLOSEDIR
            pla
            plp
            bcc   :haveent
            cmp   #0
            bne   :rderr

*-- Empty. Destroy this directory, then return to the parent.
            jsr   CPT_MKS
            lda   #<CPT_MP
            sta   CPT_DP_PATH
            lda   #>CPT_MP
            sta   CPT_DP_PATH+1
            lda   #<CPT_DP
            ldx   #>CPT_DP
            jsr   SC_UNLINK
            bcs   :err
            lda   CPT_DEPTH
            bne   :pop
            clc
            rts
:pop        dec   CPT_DEPTH
            ldx   CPT_DEPTH
            lda   CPT_STKS,x
            sta   CPT_SLEN
            tax
            stz   CPT_SRC,x
            jmp   CPT_RMLOOP
:rderr      sta   CPT_ERR
            sec
            rts
:operr      sta   CPT_ERR
            sec
            rts
:err        sta   CPT_ERR
            sec
            rts

:haveent    lda   CPT_SLEN
            sta   CPT_OSL
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
            ldy   #RD_STYPE
            lda   CPT_REC,y
            cmp   #STYP_DIR
            beq   :descend
            cmp   #CPT_STYPVOL
            beq   :descend
*-- a plain file: destroy it and take the next entry zero
            jsr   CPT_MKS
            lda   #<CPT_MP
            sta   CPT_DP_PATH
            lda   #>CPT_MP
            sta   CPT_DP_PATH+1
            lda   #<CPT_DP
            ldx   #>CPT_DP
            jsr   SC_UNLINK
            bcs   :err
            lda   CPT_OSL
            sta   CPT_SLEN
            tax
            stz   CPT_SRC,x
            jmp   CPT_RMLOOP
:descend    lda   CPT_DEPTH
            cmp   #CPT_MAXDEP
            bcs   :toodeep
            ldx   CPT_DEPTH
            lda   CPT_OSL
            sta   CPT_STKS,x
            inc   CPT_DEPTH
            jmp   CPT_RMLOOP
:toodeep    lda   #CPTE_DEEP
            sta   CPT_ERR
            sec
            rts
:long       lda   #CPTE_LONG
            sta   CPT_ERR
            sec
            rts

*---------------------------------------------------------------
* CPT_MKDIR -- CREATE CPT_DST as a subdirectory. A directory is
* just a CREATE with storage_type $0D and file_type $0F --
* src/bin/mkdir.s's whole utility, two bytes.
*
* An EXISTING DIRECTORY is SUCCESS. That is `cp -r`'s merge (the
* host merges into an existing directory rather than refusing)
* and it is also the empty-DST case `mv` allows; `mv`'s stricter
* rule -- refuse a NON-EMPTY existing DST -- is enforced by the
* caller before the walk starts, not here, because it applies
* only to the ROOT of the move. An existing FILE is a failure.
*---------------------------------------------------------------
CPT_MKDIR   jsr   CPT_MKD
            lda   #FTYPE_DIR
            sta   CPT_CR_FTYP
            lda   #STYP_DIR
            sta   CPT_CR_STYP
            stz   CPT_CR_AUX
            stz   CPT_CR_AUX+1
            lda   #<CPT_CR
            ldx   #>CPT_CR
            jsr   SC_CREAT
            bcc   :ok
            cmp   #CPT_EDUP
            bne   :err
            jsr   CPT_STATD
            bcs   :err
            lda   CPT_GF_STYP
            cmp   #STYP_DIR
            beq   :ok
            cmp   #CPT_STYPVOL
            beq   :ok
            lda   #CPT_EDUP           ;exists, and is a FILE
:err        sta   CPT_ERR
            sec
            rts
:ok         clc
            rts

*---------------------------------------------------------------
* CPT_STATD -- GET_FILE_INFO on the destination (CPT_MP2, which
* the caller has already built). Repointing CPT_GF_PATH is safe
* here where it was NOT safe in mv.s: that cell is a dum cell,
* not program text, so a warm bank cannot inherit it
* (learning:01M0T103ZQSAEGQ5D8FS8XZ8V4). It is still written
* before every read rather than relying on an initializer.
*---------------------------------------------------------------
CPT_STATD   lda   #<CPT_MP2
            sta   CPT_GF_PATH
            lda   #>CPT_MP2
            sta   CPT_GF_PATH+1
            lda   #<CPT_GF
            ldx   #>CPT_GF
            jmp   SC_GFI

*---------------------------------------------------------------
* CPT_STATS -- GET_FILE_INFO on the source (CPT_MP).
*---------------------------------------------------------------
CPT_STATS   lda   #<CPT_MP
            sta   CPT_GF_PATH
            lda   #>CPT_MP
            sta   CPT_GF_PATH+1
            lda   #<CPT_GF
            ldx   #>CPT_GF
            jmp   SC_GFI

*---------------------------------------------------------------
* CPT_COPY1 -- copy the one regular file CPT_SRC to CPT_DST,
* preserving file_type/aux_type. This is mv.s's COPYFILE with
* the DSTRESOLV branches removed: inside a fresh mirror the
* destination cannot already exist, and when `cp -r` is merging
* into an existing tree the duplicate-name path below does what
* cp.s already does -- destroy and retry CREATE, because CREATE
* is the only call that sets file_type/aux_type and it never
* touches an existing entry.
*
* A DIRECTORY destination is REFUSED rather than destroyed:
* DESTROY empties an EMPTY subdirectory quite happily (P8 TRM
* 4.4.2), so a blind destroy would silently replace a directory
* with a file. mv.s and cp.s both carry this guard already.
*
* The SOURCE cannot be a directory here -- the walk dispatched
* on storage_type before calling -- so there is no dir-SRC guard
* to repeat. Carry set on any failure, CPT_ERR = MLI errno.
*---------------------------------------------------------------
CPT_COPY1   jsr   CPT_MKS
            jsr   CPT_STATS
            bcc   :statok
*-- TRAMPOLINE. :ferr sits past the whole copy loop, out of a
*-- plain bcs's +/-127 from up here -- the same `bcc :near /
*-- jmp :far` shape mv.s's COPYFILE and cp.s both needed more
*-- than once. Every early exit above the loop goes through it.
:nferr      jmp   :ferr
:statok     lda   CPT_GF_FTYP
            sta   CPT_CR_FTYP
            lda   CPT_GF_AUX
            sta   CPT_CR_AUX
            lda   CPT_GF_AUX+1
            sta   CPT_CR_AUX+1
            lda   #STYP_SEEDLING
            sta   CPT_CR_STYP
            jsr   CPT_MKD
            lda   #<CPT_CR
            ldx   #>CPT_CR
            jsr   SC_CREAT
            bcc   :created
            cmp   #CPT_EDUP
            bne   :nferr
*-- destination exists. Refuse a directory; replace a file.
            jsr   CPT_STATD
            bcs   :nferr
            lda   CPT_GF_STYP
            cmp   #STYP_DIR
            beq   :dstdir
            cmp   #CPT_STYPVOL
            bne   :notdir
:dstdir     lda   #CPT_EDUP
            bra   :nferr
:notdir     lda   #<CPT_MP2
            sta   CPT_DP_PATH
            lda   #>CPT_MP2
            sta   CPT_DP_PATH+1
            lda   #<CPT_DP
            ldx   #>CPT_DP
            jsr   SC_UNLINK
            bcs   :nferr
            lda   #<CPT_CR
            ldx   #>CPT_CR
            jsr   SC_CREAT
            bcs   :nferr
:created    lda   #<CPT_OP
            ldx   #>CPT_OP
            jsr   SC_OPEN
            bcs   :nferr
            lda   CPT_OP_REF
            sta   CPT_SFD
            lda   #<CPT_O2
            ldx   #>CPT_O2
            jsr   SC_OPEN
            bcc   :dstok
            pha
            jsr   CPT_CLOSES
            pla
            jmp   :ferr           ;same: past the copy loop
:dstok      lda   CPT_O2_REF
            sta   CPT_DFD

:loop       lda   CPT_SFD
            sta   CPT_RP_REF
            lda   #<CPT_RP
            ldx   #>CPT_RP
            jsr   SC_READ
*-- carry SET is a REAL error, never clean EOF: the kernel folds
*-- MLI_ERR_EOF into clc with trans_count 0 (procfile2.s
*-- PRC_FILE_READ). Treating carry as EOF is the regression
*-- mv.s's own header records -- it reported success on 0 bytes
*-- moved.
            bcs   :ioerr
            lda   CPT_RP_TRAN
            ora   CPT_RP_TRAN+1
            beq   :eof
            lda   CPT_DFD
            sta   CPT_WP_REF
            lda   CPT_RP_TRAN
            sta   CPT_WP_REQ
            lda   CPT_RP_TRAN+1
            sta   CPT_WP_REQ+1
            lda   #<CPT_WP
            ldx   #>CPT_WP
            jsr   SC_WRITE
            bcs   :ioerr
            bra   :loop
:eof        jsr   CPT_CLOSEB
            clc
            rts
:ioerr      pha
            jsr   CPT_CLOSEB
            pla
:ferr       sta   CPT_ERR
            sec
            rts

*---------------------------------------------------------------
* CPT_CLOSES / CPT_CLOSEB -- close the source fd, or both.
*---------------------------------------------------------------
CPT_CLOSES  lda   CPT_SFD
            sta   CPT_CL_REF
            lda   #<CPT_CL
            ldx   #>CPT_CL
            jmp   SC_CLOSE

CPT_CLOSEB  jsr   CPT_CLOSES
            lda   CPT_DFD
            sta   CPT_CL_REF
            lda   #<CPT_CL
            ldx   #>CPT_CL
            jmp   SC_CLOSE

*---------------------------------------------------------------
* CPT_ISDESC -- IN: PTR0 = base, PTR1 = candidate, both liba
* strings. OUT: carry SET if the candidate IS the base or lies
* strictly beneath it.
*
* A PLAIN PREFIX COMPARE IS NOT ENOUGH: "/T/AB" starts with
* "/T/A" and is not inside it. The character after the matched
* prefix must be the separator, or the end of the string.
* CLOBBERS: A, Y.
*---------------------------------------------------------------
CPT_ISDESC  ldy   #0
:cmp        lda   (PTR0),y
            beq   :baseend
            cmp   (PTR1),y
            bne   :no
            iny
            bne   :cmp
:no         clc
            rts
:baseend    lda   (PTR1),y
            beq   :yes                ;the very same path
            cmp   #"/"
            beq   :yes                ;base + "/" + something
            clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* CPT_UNPATH -- IN: A/X = an MLI-shaped path (count byte then
* 7-bit chars), PTR1 = destination. Writes it out as a liba
* string (high-bit, NUL-terminated) and returns its length in A.
* MKPATH's inverse, for cp.s, which converts both operands to
* MLI paths up front and needs the string form this module
* walks in. CLOBBERS: A, X, Y, PTR0.
*---------------------------------------------------------------
CPT_UNPATH  sta   PTR0
            stx   PTR0+1
            ldy   #0
            lda   (PTR0),y
            sta   CPT_TMP             ;count
            beq   :done
:loop       iny
            lda   (PTR0),y
            ora   #$80
            dey
            sta   (PTR1),y
            iny
            cpy   CPT_TMP
            bne   :loop
:done       ldy   CPT_TMP
            lda   #0
            sta   (PTR1),y
            lda   CPT_TMP
            rts
