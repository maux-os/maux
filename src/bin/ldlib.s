*---------------------------------------------------------------
* ldlib.s -- `-l` and the LIB directory.
* See docs/LD-NATIVE.md section 2.
*
* A LIBRARY IS A DIRECTORY of REL objects. maux needs no archive
* format because ProDOS directories already are one and readdir
* already works -- no ranlib, no index to go stale, and
* `ls /LIB/LIBC` tells you what is in it.
*
* `-l c` searches for the directory LIBC under each `-L` path in
* command-line order, then under the built-in DEFLIB. Members
* are pulled in SELECTIVELY, which is what makes this a real
* `-l` and not a glob: a member is linked only if it defines a
* symbol that is currently UNDEFINED, and because one can create
* new undefined symbols, each library is rescanned until a pass
* adds nothing. Then the next `-l`. Order matters, as in Unix.
*
* PLACEMENT: the fixpoint decides the SET, the directory decides
* the ORDER, and the flag's position among the operands decides
* WHERE -- taken members are spliced into the module list at the
* `-l`'s own place, in directory (= creation) order. Discovery
* order would vary with which pass found a member; directory
* order is what lets a kernel library staged in put order link
* byte-identical to the monolithic image (S9-PLAN 6b).
*
* ONE OPENDIR AT A TIME (src/liba/readdir.s keeps a single block
* buffer and cursor), so a pass COLLECTS THE MEMBER NAMES FIRST
* and closes the directory before opening any member.
*---------------------------------------------------------------

*---------------------------------------------------------------
* ADDLIBD -- record a -L search directory (path at PTR0).
*---------------------------------------------------------------
ADDLIBD     lda   NLIBD
            cmp   #LIBDMAX
            bcs   :full
            jsr   LD_POOLW
            bcs   :full
            ldx   NLIBD
            lda   ND_TMP2
            sta   LIBDOF_L,x
            lda   ND_TMP2+1
            sta   LIBDOF_H,x
            inc   NLIBD
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* ADDLIBR -- record a -l library name (name at PTR0).
*---------------------------------------------------------------
ADDLIBR     lda   NLIBR
            cmp   #LIBRMAX
            bcs   :full
            jsr   LD_POOLW
            bcs   :full
            ldx   NLIBR
            lda   ND_TMP2
            sta   LIBROF_L,x
            lda   ND_TMP2+1
            sta   LIBROF_H,x
*-- the flag is POSITIONAL: members splice into the module list
*-- where the -l stood among the operands, so record how many
*-- modules were named before it.
            lda   NMODS
            sta   LIBPOS,x
            inc   NLIBR
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* LD_POOLW -- copy PTR0's NUL-terminated string into LIBPOOL.
* OUT: ND_TMP2 = its offset, carry set if the pool is full.
*---------------------------------------------------------------
LD_POOLW    lda   LIBUSED
            sta   ND_TMP2
            lda   LIBUSED+1
            sta   ND_TMP2+1
            clc
            lda   #<LIBPOOL
            adc   LIBUSED
            sta   ND_TMP
            lda   #>LIBPOOL
            adc   LIBUSED+1
            sta   ND_TMP+1
            ldy   #0
:cpy        lda   (PTR0),y
            sta   (ND_TMP),y
            beq   :done
            iny
            cpy   #64
            bcc   :cpy
            sec
            rts
:done       iny
            clc
            tya
            adc   LIBUSED
            sta   LIBUSED
            lda   LIBUSED+1
            adc   #0
            sta   LIBUSED+1
            cmp   #>LIBPLCAP
            bcs   :full
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* SEEDUNDEF -- after the explicit modules are placed, collect
* every EXT they name that no ENT has defined. That set is what
* the libraries are searched to satisfy.
*---------------------------------------------------------------
*-- TWO SWEEPS, and the order is the whole point. The first
*-- publishes every explicit module's ENTs; only then can the
*-- second ask whether an EXT is undefined. Collecting EXTs
*-- against an EMPTY pool -- which is what this did first --
*-- marks every reference undefined, including ones another
*-- named module already satisfies, and a library is then
*-- searched for symbols that are not missing.
SEEDUNDEF   stz   SEEDPHASE
:phase      stz   ND_I
:modloop    lda   ND_I
            cmp   NMODS
            bcc   :more
            lda   SEEDPHASE
            bne   :bothdone
            inc   SEEDPHASE
            bra   :phase
:bothdone   clc
            rts
:more       jsr   OPENMOD
            bcs   :fail
            jsr   READTAIL
            bcs   :closefail
            lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            jsr   SKIPFIX
:symloop    jsr   SYMREC
            bcs   :symdone
            lda   SEEDPHASE
            bne   :wantext
            lda   ND_FLAG            ;phase 0 -- publish ENTs
            and   #FLAG_ENT
            beq   :symloop
            jsr   ADDSYM
            bcs   :closefail
            bra   :symloop
:wantext    lda   ND_FLAG            ;phase 1 -- collect EXTs
            and   #FLAG_EXT
            beq   :symloop
            jsr   FINDSYM
            bcc   :symloop           ;defined already
            jsr   ADDUNDEF
            bcs   :closefail
            bra   :symloop
:symdone    jsr   CLOSEMOD
            inc   ND_I
            jmp   :modloop
:closefail  jsr   CLOSEMOD
:fail       sec
            rts

*---------------------------------------------------------------
* ADDUNDEF -- append ND_NAME/ND_LEN to the undefined pool if it
* is not already there. Entries are [len][name], $00-terminated.
*---------------------------------------------------------------
ADDUNDEF    jsr   FINDUNDEF
            bcc   :already
            clc
            lda   #<UNDEFPOOL
            adc   UNDUSED
            sta   ND_TMP
            lda   #>UNDEFPOOL
            adc   UNDUSED+1
            sta   ND_TMP+1
            ldy   #0
            lda   ND_LEN
            sta   (ND_TMP),y
:cpy        cpy   ND_LEN
            beq   :cpydone
            lda   (ND_NAME),y
            iny
            sta   (ND_TMP),y
            bra   :cpy
:cpydone    ldy   ND_LEN
            iny
            lda   #0
            sta   (ND_TMP),y
            clc
            lda   UNDUSED
            adc   ND_LEN
            sta   UNDUSED
            lda   UNDUSED+1
            adc   #0
            sta   UNDUSED+1
            inc   UNDUSED
            bne   :nocy
            inc   UNDUSED+1
:nocy       lda   UNDUSED+1
            cmp   #>UNDPLCAP
            bcs   :full
:already    clc
            rts
:full       jsr   ERR_SYMS           ;was a SILENT exit 1
            sec
            rts

*---------------------------------------------------------------
* FINDUNDEF -- is ND_NAME/ND_LEN in the undefined pool?
* Carry clear = yes, ND_PTR2 points at its length byte.
*---------------------------------------------------------------
FINDUNDEF   lda   #<UNDEFPOOL
            sta   ND_PTR2
            lda   #>UNDEFPOOL
            sta   ND_PTR2+1
:loop       ldy   #0
            lda   (ND_PTR2),y
            beq   :miss
            cmp   ND_LEN
            bne   :next
            jsr   CMPNAM
            bcc   :hit
:next       ldy   #0
            lda   (ND_PTR2),y
            clc
            adc   #1
            jsr   ADVPTR2
            bra   :loop
:hit        clc
            rts
:miss       sec
            rts

*---------------------------------------------------------------
* LIBRESOLVE -- the whole of `-l`, run BEFORE pass 1.
*
* Selection needs only symbol NAMES, not addresses, so it reuses
* the ordinary symbol pool with a base of zero and the pool is
* RESET afterwards; pass 1 then places every module -- explicit
* and library alike -- and fills the pool properly. That is why
* there is no second symbol table here.
*
* A member is WANTED if it defines a name that some placed
* module referenced (it is in the undefined pool) and that no
* placed module defines yet (FINDSYM misses). Once included, its
* ENTs enter the pool, so the same member cannot be chosen
* twice and no "already linked" flag is needed.
*---------------------------------------------------------------
LIBRESOLVE  lda   NLIBR
            bne   :work
            clc
            rts
:work       stz   ND_BASE
            stz   ND_BASE+1
            jsr   SEEDUNDEF
            bcs   :fail
            stz   LIBI
:reqloop    lda   LIBI
            cmp   NLIBR
            bcs   :done
            jsr   LIBDIRFOR
            bcs   :fail
            stz   TAKEUSED           ;this request's take list
            stz   TAKEUSED+1
            stz   TAKEPOOL
:sweep      stz   LIBCHG
            jsr   SCANLIB
            bcs   :fail
            lda   LIBCHG
            bne   :sweep             ;a member came in
            jsr   LIBSPLICE          ;place the takes
            bcs   :fail
            inc   LIBI
            bra   :reqloop
:done       stz   NAMEPOOL           ;pass 1 refills it with
            stz   NAMEUSED           ;real addresses
            stz   NAMEUSED+1
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* LIBDIRFOR -- build LIBDBUF = "<dir>/LIB<name>" for request
* LIBI, trying each -L path in order and then DEFLIB.
* OUT: carry clear, LIBDBUF holds a directory that opened.
*---------------------------------------------------------------
LIBDIRFOR   stz   LIBD
:try        lda   LIBD
            cmp   NLIBD
            bcc   :havedir
            beq   :usedflt
            jsr   ERR_NOLIB
            sec
            rts
:havedir    ldx   LIBD
            clc
            lda   #<LIBPOOL
            adc   LIBDOF_L,x
            sta   PTR0
            lda   #>LIBPOOL
            adc   LIBDOF_H,x
            sta   PTR0+1
            bra   :compose
:usedflt    lda   #<DEFLIB
            sta   PTR0
            lda   #>DEFLIB
            sta   PTR0+1
:compose    jsr   LIBCOMPOSE
            lda   #<LIBDBUF
            sta   PTR0
            lda   #>LIBDBUF
            sta   PTR0+1
            lda   #<LIBPATH
            sta   PTR1
            lda   #>LIBPATH
            sta   PTR1+1
            jsr   MKPATH
            lda   #<LIBPATH
            ldx   #>LIBPATH
            jsr   OPENDIR
            bcs   :next
            jsr   CLOSEDIR
            clc
            rts
:next       inc   LIBD
            bra   :try
