*---------------------------------------------------------------
* seek.s -- liba's elegant layer over the kernel's plain seek-
* family MLI delegates (SC_SETMARK/SC_GETMARK/SC_GETEOF/
* SC_SETEOF, src/liba/syscalls.s; PRC_SETMARK/PRC_GETMARK/
* PRC_GETEOF/PRC_SETEOF, src/kernel/procfile.s). docs/FLEET.md
* "`>>` and the seek family" is the ruling this implements:
*   SEEK_SET is SET_MARK alone
*   SEEK_CUR is GET_MARK then SET_MARK
*   SEEK_END is GET_EOF then SET_MARK
* Own module per the #8a convention (small, single-concern liba
* files -- print.s/mli.s/num.s/string.s and friends), and
* because neither merlin32 nor real Merlin nests PUT
* (docs/TOOLCHAIN.md/commit 004bd02): every top-level
* src/bin/*.s program that wants LSEEK PUTs this file directly,
* alongside syscalls.s.
*---------------------------------------------------------------

* -- SEEK_SET/SEEK_CUR/SEEK_END moved to inc/zp.equ: they
* -- were forward references for every caller assembled before
* -- this file's own `put`, which real Merlin-8 rejects. See
* -- that file's "CONSTANTS THAT ARE NOT ZERO PAGE" section.

* -- param_count for all four MLI seek-family calls (SET_MARK/
* -- GET_MARK/GET_EOF/SET_EOF, P8 TRM 4.5.6-4.5.9: ref_num +
* -- a 3-byte value). STORED by LSEEK rather than emitted --
* -- see this file's trailer.
SEEK_PCOUNT equ   2

* -- Not a real MLI/kernel errno -- LSEEK's own input-validation
* -- sentinel for a whence value none of SEEK_SET/CUR/END match.
* -- No caller in this tree passes one (sh's `>>` always passes
* -- SEEK_END); kept defensive rather than assumed unreachable.
LSK_BADWHENCE equ $FF

*---------------------------------------------------------------
* LSEEK -- lseek(fd, offset, whence). ProDOS's file mark is 3
* bytes (files to 16MB), so offset is a 3-byte little-endian
* value, not 16 bits -- V7's lseek shape, not V6's block-unit
* seek (docs/FLEET.md's own "why lseek and not V6's seek").
*
* IN:  A = fd
*      Y = whence (SEEK_SET=0, SEEK_CUR=1, SEEK_END=2)
*      PTR0 = pointer to a 3-byte little-endian offset buffer.
*        SEEK_SET: the absolute target position.
*        SEEK_CUR/SEEK_END: a NON-NEGATIVE delta added to the
*        current mark / EOF (v1 -- no signed-offset support;
*        the one real caller in this tree, sh's `>>`, always
*        passes 0, and this codebase's habit is not to build
*        arithmetic nothing yet calls for -- see CHCK_BLTN_EXT's
*        own decimal-parser precedent in src/bin/sh.s).
* OUT: carry clear = ok, the 3 bytes AT (PTR0) overwritten with
*        the RESULTING absolute mark (so a caller never needs a
*        follow-up GET_MARK just to learn where it landed).
*      carry set = error, A = errno (or LSK_BADWHENCE for a bad
*        `whence`); the 3 bytes at (PTR0) are left undefined.
* CLOBBERS: A, X, Y. PTR0 the POINTER is preserved; the 3 bytes
* it points AT are not (see OUT above). Composes SC_GETMARK/
* SC_GETEOF/SC_SETMARK, each of which clobbers Y with no
* restore (src/liba/syscalls.s's own register-discipline
* note) -- LSEEK never relies on Y surviving any of those
* calls itself.
*---------------------------------------------------------------
LSEEK       sta   LSK_FD
            lda   #SEEK_PCOUNT     ;stored, not emitted -- the
            sta   SEEK_PARM        ;parmlist is in bss now (A is
                                   ;dead here: every path below
                                   ;reloads it)
            cpy   #SEEK_SET
            beq   :isset
            cpy   #SEEK_CUR
            beq   :iscur
            cpy   #SEEK_END
            beq   :isend
            lda   #LSK_BADWHENCE
            sec
            rts

:isset      ldy   #0
:cpoff      lda   (PTR0),y
            sta   SEEK_PARM_VAL,y
            iny
            cpy   #3
            bne   :cpoff
            bra   :callset

:iscur      lda   LSK_FD
            sta   SEEK_PARM_REF
            lda   #<SEEK_PARM
            ldx   #>SEEK_PARM
            jsr   SC_GETMARK
            bcs   :fail
            jsr   LSK_ADD_OFF
            bra   :callset

:isend      lda   LSK_FD
            sta   SEEK_PARM_REF
            lda   #<SEEK_PARM
            ldx   #>SEEK_PARM
            jsr   SC_GETEOF
            bcs   :fail
            jsr   LSK_ADD_OFF
            ;fall through to :callset

:callset    lda   LSK_FD
            sta   SEEK_PARM_REF
            lda   #<SEEK_PARM
            ldx   #>SEEK_PARM
            jsr   SC_SETMARK
            bcs   :fail
            ldy   #0
:cpback     lda   SEEK_PARM_VAL,y
            sta   (PTR0),y
            iny
            cpy   #3
            bne   :cpback
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* LSK_ADD_OFF -- SEEK_PARM_VAL += the 3-byte value at (PTR0),
* little-endian, in place. v1: unsigned/non-negative offsets
* only (see LSEEK's own header). CLOBBERS: A, Y.
*---------------------------------------------------------------
LSK_ADD_OFF
            clc
            ldy   #0
:add        lda   SEEK_PARM_VAL,y
            adc   (PTR0),y
            sta   SEEK_PARM_VAL,y
            iny
            cpy   #3
            bne   :add
            rts

* -- LSK_FD and the 5-byte SEEK_PARM block used to be declared
* -- here as emitted `ds`/`dfb` text that LSEEK then wrote --
* -- writable text, which docs/STICKY.md sec 21 forbids. They
* -- are in src/liba/libabss.s's `dum` arena now (sec 25), with
* -- their read-before-write trace recorded beside them. The one
* -- constant, param_count, is STORED at the top of LSEEK
* -- because an MLI parmlist must be CONTIGUOUS and so cannot
* -- leave a single byte behind in text.
