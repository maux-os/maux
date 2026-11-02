*---------------------------------------------------------------
* mntdens.s -- mount's S3 half (docs/LOOP-S2.md): make a SPARSE
* image dense before it is attached read-write. A put file, not
* a
* program; mount.s owns the arena cells it names.
*
* ProDOS allocates only what was written, and only a WRITE
* allocates (TN #30; the loop driver has no allocator and
* answers
* $27 on a hole). So: an image file of N blocks (N > 256, a
* tree)
* is dense iff blocks_used = N + 1 + ceil(N/256) (data, the
* index
* blocks, the master). GET_FILE_INFO gives blocks_used; no block
* map is walked here. If it is short, every all-zero block of
* the
* file is rewritten with zeros (a hole reads as zeros; writing
* them
* back allocates it, and allocated zero blocks are only
* rewritten
* with what they hold), then blocks_used is read again: the
* difference is "densified N blocks", and anything still short
* is
* the kernel's sparse refusal to report.
*
* Skipped when the file is not writable (the kernel mounts it
* read-only and tolerates the holes) and for N <= 256 (the
* kernel
* says "not a tree file").
*
* IN:  MLIPATH = the absolute 7-bit path. OUT: carry CLEAR, or
* carry SET and A = the MLI's reason. CLOBBERS: A, X, Y, PTR0,
* PTR1, U2DEC_*.
*---------------------------------------------------------------
DENSIFY     lda   #PCOUNT_GFI       ;writable? how many blocks?
            sta   DGFI
            lda   #<MLIPATH
            sta   DGFI_PATH
            lda   #>MLIPATH
            sta   DGFI_PATH+1
            lda   #<DGFI
            ldx   #>DGFI
            jsr   SC_GFI
            bcc   :g1
            rts
:g1         lda   DGFI_ACC
            and   #2
            bne   :wr
*-- read-only file: nothing to do
            clc
            lda   #0
            rts
:wr
            lda   DGFI_BLKS
            sta   DBEFORE
            lda   DGFI_BLKS+1
            sta   DBEFORE+1
            lda   #PCOUNT_OPEN
            sta   DOPN
            lda   #<MLIPATH
            sta   DOPN_PATH
            lda   #>MLIPATH
            sta   DOPN_PATH+1
            stz   DOPN_IOB
            stz   DOPN_IOB+1
            lda   #<DOPN
            ldx   #>DOPN
            jsr   SC_OPEN
            bcc   :o1
            rts
:o1         lda   DOPN_REF
            sta   DFD
            lda   #2
            sta   DEOF
            lda   DFD
            sta   DEOF+1
            lda   #<DEOF
            ldx   #>DEOF
            jsr   SC_GETEOF
            bcc   :ge
            jmp   DCERR
:ge
*-- N = ceil(EOF/512); DLAST = bytes in the last block (1-512)
            lda   DEOF+4
            lsr   a
            sta   DN+1
            lda   DEOF+3
            ror   a
            sta   DN
            lda   DEOF+3
            and   #1
            sta   DLAST+1
            lda   DEOF+2
            sta   DLAST
            ora   DLAST+1
            bne   :tail
            lda   #2                ;an exact multiple: 512
            sta   DLAST+1
            bra   :n
:tail       inc   DN
            bne   :n
            inc   DN+1
:n          lda   DN+1
            cmp   #1
            bcc   DCLOSE            ;N < 256
            bne   :big
            lda   DN
            beq   DCLOSE            ;N = 256: a sapling
*-- expected = N + 1 + ceil(N/256) = N + 1 + N.hi + (N.lo <> 0)
:big        lda   DN
            sec
            adc   #0
            sta   DEXP
            lda   DN+1
            adc   #0
            sta   DEXP+1
            lda   DEXP
            clc
            adc   DN+1
            sta   DEXP
            bcc   :nl
            inc   DEXP+1
:nl         lda   DN
            beq   :nz
            inc   DEXP
            bne   :nz
            inc   DEXP+1
:nz         lda   DBEFORE+1
            cmp   DEXP+1
            bcc   :sparse
            bne   DCLOSE
            lda   DBEFORE
            cmp   DEXP
*-- blocks_used >= expected: dense
            bcs   DCLOSE
:sparse     stz   DI
            stz   DI+1
            bra   DBLK
DCLOSE      jsr   DCLS              ;nothing to do
            bcs   DRET
DOK         clc
            lda   #0
DRET        rts
DCERR       pha                     ;close, keep the reason
            jsr   DCLS
            pla
            sec
            rts

DCLS        lda   #PCOUNT_CLOSE
            sta   DCLP
            lda   DFD
            sta   DCLP+1
            lda   #<DCLP
            ldx   #>DCLP
            jmp   SC_CLOSE

*-- every block: zeros read back? write the zeros
DBLK        ldy   #0
            tya
:clr        sta   CBUF,y
            sta   CBUF+256,y
            iny
            bne   :clr
            jsr   DSEEK
            bcs   DCERR
            lda   #4
            sta   DRW
            lda   DFD
            sta   DRW+1
            lda   #<CBUF
            sta   DRW+2
            lda   #>CBUF
            sta   DRW+3
            jsr   DREQ
            lda   #<DRW
            ldx   #>DRW
            jsr   SC_READ
            bcs   DCERR
            ldy   #0
:zt         lda   CBUF,y
            ora   CBUF+256,y
            bne   :next
            iny
            bne   :zt
            jsr   DSEEK             ;all zeros: write them back
            bcs   DCERR
            jsr   DREQ
            lda   #<DRW
            ldx   #>DRW
            jsr   SC_WRITE
            bcs   DCERR
:next       inc   DI
            bne   :c
            inc   DI+1
:c          lda   DI
            cmp   DN
            bne   DBLK
            lda   DI+1
            cmp   DN+1
            bne   DBLK
            jsr   DCLS
            bcc   :cl
            rts
:cl         lda   #<DGFI            ;how many did that allocate?
            ldx   #>DGFI
            jsr   SC_GFI
            bcc   :g2
            rts
:g2         sec
            lda   DGFI_BLKS
            sbc   DBEFORE
            sta   U2DEC_VAL
            lda   DGFI_BLKS+1
            sbc   DBEFORE+1
            sta   U2DEC_VAL+1
            ora   U2DEC_VAL
            bne   :msg
            jmp   DOK
:msg        lda   #<PROGNAME
            sta   PTR0
            lda   #>PROGNAME
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<MNT_COLON
            sta   PTR0
            lda   #>MNT_COLON
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   OPSAVE
            sta   PTR0
            lda   OPSAVE+1
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #<DMSG2
            sta   PTR0
            lda   #>DMSG2
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            ldx   #FD_STDERR
            jsr   PRNUM
            lda   #<DMSG3
            sta   PTR0
            lda   #>DMSG3
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            jmp   DOK
*-- SET_MARK to DI * 512 (mark.lo = 0, mid = DI.lo*2, hi = ...)
DSEEK       lda   #2
            sta   DSM
            lda   DFD
            sta   DSM+1
            stz   DSM+2
            lda   DI
            asl   a
            sta   DSM+3
            lda   DI+1
            rol   a
            sta   DSM+4
            lda   #<DSM
            ldx   #>DSM
            jmp   SC_SETMARK

*-- the request: 512, or DLAST for the file's last block
DREQ        lda   #0
            sta   DRW+4
            lda   #2
            sta   DRW+5
            lda   DI
            sec
            adc   #0                ;DI + 1 ...
            tax
            lda   DI+1
            adc   #0
            cpx   DN                ;... = N: the last block
            bne   :full
            cmp   DN+1
            bne   :full
            lda   DLAST
            sta   DRW+4
            lda   DLAST+1
            sta   DRW+5
:full       rts

DMSG2       asc   ": densified "
            dfb   0
DMSG3       asc   " blocks"
            dfb   $8D,0
