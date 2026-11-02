*---------------------------------------------------------------
* ldscan.s -- the library directory scan: path composition, the
* member list, and the selective inclusion test. Split from
* ldlib.s at LIBCOMPOSE for check-dialect's window.
*---------------------------------------------------------------
*---------------------------------------------------------------
* COMPOSEDIR -- LIBDBUF = PTR0 + "/". Shared directory-join
* prologue for LIBCOMPOSE (-l: appends "LIB"+name below) and
* MODCOMPOSE (-L module resolution, ldpass.s OPENMOD: appends a
* bare module name) -- factored out 2026-09-25 so the -L
* directory-join logic exists in exactly one place. OUT: Y =
* ND_LEN = bytes written (the trailing "/" included).
*---------------------------------------------------------------
COMPOSEDIR  ldy   #0
:cpdir      lda   (PTR0),y
            beq   :dirdone
            sta   LIBDBUF,y
            iny
            cpy   #48
            bcc   :cpdir
:dirdone    lda   #"/"
            sta   LIBDBUF,y
            iny
            sty   ND_LEN
            rts

*---------------------------------------------------------------
* LIBCOMPOSE -- LIBDBUF = PTR0 + "/LIB" + request LIBI's name.
* Everything is liba high-bit ASCII.
*---------------------------------------------------------------
LIBCOMPOSE  jsr   COMPOSEDIR
            lda   #"L"
            sta   LIBDBUF,y
            iny
            lda   #"I"
            sta   LIBDBUF,y
            iny
            lda   #"B"
            sta   LIBDBUF,y
            iny
            sty   ND_LEN
            ldx   LIBI
            clc
            lda   #<LIBPOOL
            adc   LIBROF_L,x
            sta   ND_TMP
            lda   #>LIBPOOL
            adc   LIBROF_H,x
            sta   ND_TMP+1
            ldy   #0
:cpnam      lda   (ND_TMP),y
            beq   :namdone
            phy
            ldy   ND_LEN
            sta   LIBDBUF,y
            inc   ND_LEN
            ply
            iny
            cpy   #16
            bcc   :cpnam
:namdone    ldy   ND_LEN
            lda   #0
            sta   LIBDBUF,y
            rts

*---------------------------------------------------------------
* MODCOMPOSE -- LIBDBUF = PTR0 + "/" + the module name at
* MODNAMEP (ldpass.s OPENMOD's own saved pointer, since PTR0 is
* this routine's -L directory argument, not the module name).
* -l's own -L search (LIBCOMPOSE, above) and -L module
* resolution (this routine) share COMPOSEDIR's directory-join
* prologue; only the suffix differs, a bare module name here
* instead of "LIB"+library short name. No 16-char cap: module
* names run up to ADDMOD's own 64-char pool bound (ldpass.s).
*---------------------------------------------------------------
MODCOMPOSE  jsr   COMPOSEDIR
            ldy   #0
:cpnam      lda   (MODNAMEP),y
            beq   :namdone
            phy
            ldy   ND_LEN
            sta   LIBDBUF,y
            inc   ND_LEN
            ply
            iny
            cpy   #65
            bcc   :cpnam
:namdone    ldy   ND_LEN
            lda   #0
            sta   LIBDBUF,y
            rts

*---------------------------------------------------------------
* SCANLIB -- one pass over the current library directory.
*
* COLLECTS THE MEMBER NAMES FIRST and closes the directory,
* because only one OPENDIR may be live at a time and every
* member has to be opened as a file afterwards. Sets LIBCHG if
* anything was pulled in, which is what drives the rescan.
*---------------------------------------------------------------
SCANLIB     stz   MEMUSED
            stz   MEMUSED+1
            lda   #<LIBPATH
            ldx   #>LIBPATH
            jsr   OPENDIR
            bcs   :noopen
:rdloop     lda   #<RDREC
            ldx   #>RDREC
            jsr   READDIR
            bcs   :rddone
            lda   RDREC+RD_FTYPE
*-- FTYPE_RELM ($F8), NOT FTYPE_REL ($FE): $FE is the REGISTERED
*-- relocatable type, which is EDASM's ESD/RLD format. Merlin
*-- writes $F8. mli.equ says so in its own comment and I still
*-- reached for the obvious name first.
            cmp   #FTYPE_RELM
            bne   :rdloop            ;Merlin REL only
*-- A FULL MEMBER POOL IS AN ERROR, not a stopping point. This
*-- used to `bcs :rddone`, which closed the directory and linked
*-- whatever had been collected -- so a library with more
*-- members than the pool holds was silently half-scanned, and
*-- the failure surfaced later as "undefined symbol", naming
*-- the wrong cause.
            jsr   ADDMEMBER
            bcs   :toobig
            bra   :rdloop
:toobig     jsr   CLOSEDIR
            jsr   ERR_LIBFULL
            sec
            rts
:rddone     jsr   CLOSEDIR
            jsr   TRYMEMBERS
            rts
:noopen     jsr   ERR_NOLIB
            sec
            rts

*---------------------------------------------------------------
* ADDMEMBER -- append RDREC's name to MEMPOOL as [len][name].
*---------------------------------------------------------------
ADDMEMBER   clc
            lda   #<MEMPOOL
            adc   MEMUSED
            sta   ND_TMP
            lda   #>MEMPOOL
            adc   MEMUSED+1
            sta   ND_TMP+1
            ldy   #0
            lda   RDREC
            sta   (ND_TMP),y
            sta   ND_LEN
:cpy        cpy   ND_LEN
            beq   :done
            lda   RDREC+RD_NAME,y
            iny
            sta   (ND_TMP),y
            bra   :cpy
:done       ldy   ND_LEN
            iny
            lda   #0
            sta   (ND_TMP),y
            clc
            lda   MEMUSED
            adc   ND_LEN
            sta   MEMUSED
            lda   MEMUSED+1
            adc   #0
            sta   MEMUSED+1
            inc   MEMUSED
            bne   :nocy
            inc   MEMUSED+1
:nocy       lda   MEMUSED+1
            cmp   #>MEMPLCAP
            bcs   :full
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* TRYMEMBERS -- walk MEMPOOL and pull in every member that
* defines a currently-undefined symbol.
*---------------------------------------------------------------
TRYMEMBERS  lda   #<MEMPOOL
            sta   ND_PTR3
            lda   #>MEMPOOL
            sta   ND_PTR3+1
:loop       ldy   #0
            lda   (ND_PTR3),y
            beq   :done
            sta   MEMLEN
            jsr   MEMPATH
            jsr   TRYONE
            bcs   :fail
            lda   MEMLEN
            clc
            adc   #1
            jsr   ADVPTR3
            bra   :loop
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* ADVPTR3 -- ND_PTR3 += A.
*---------------------------------------------------------------
ADVPTR3     clc
            adc   ND_PTR3
            sta   ND_PTR3
            bcc   :done
            inc   ND_PTR3+1
:done       rts

*---------------------------------------------------------------
* MEMPATH -- MEMBUF = LIBDBUF + "/" + the member name at
* ND_PTR3. Both halves are liba high-bit ASCII.
*---------------------------------------------------------------
MEMPATH     ldy   #0
:cpdir      lda   LIBDBUF,y
            beq   :dirdone
            sta   MEMBUF,y
            iny
            cpy   #56
            bcc   :cpdir
:dirdone    lda   #"/"
            sta   MEMBUF,y
            iny
            sty   ND_LEN
            ldy   #0
:cpnam      cpy   MEMLEN
            beq   :namdone
            iny
            lda   (ND_PTR3),y
            phy
            ldy   ND_LEN
            sta   MEMBUF,y
            inc   ND_LEN
            ply
            bra   :cpnam
:namdone    ldy   ND_LEN
            lda   #0
            sta   MEMBUF,y
            rts

*---------------------------------------------------------------
* TRYONE -- open the member at MEMBUF, and if it ENTs anything
* wanted, link it in: append it to the module list, publish its
* ENTs, and record its own unresolved EXTs as newly undefined.
*---------------------------------------------------------------
TRYONE      lda   #<MEMBUF
            sta   PTR0
            lda   #>MEMBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :skip
            lda   GFIPARM_AUX
            sta   ND_CODE
            lda   GFIPARM_AUX+1
            sta   ND_CODE+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :skip
            lda   OPARM_REF
            sta   MODFD
            jsr   READTAIL
            bcs   :closeskip
            jsr   MEMWANTED
            bcc   :closeskip         ;nothing wanted
            jsr   MEMTAKE
            bcs   :closefail
:closeskip  jsr   CLOSEMOD
            clc
            rts
:closefail  jsr   CLOSEMOD
:fail       sec
            rts
:skip       clc
            rts

*---------------------------------------------------------------
* MEMWANTED -- does this member ENT a name that is undefined?
* Carry SET = yes. "Undefined" is: named in the undefined pool,
* and not yet in the symbol pool -- so a member cannot be taken
* twice, and no per-member "already linked" flag is needed.
*---------------------------------------------------------------
MEMWANTED   lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            jsr   SKIPFIX
:loop       jsr   SYMREC
            bcs   :no
            lda   ND_FLAG
            and   #FLAG_ENT
            beq   :loop
            jsr   FINDUNDEF
            bcs   :loop              ;nobody asked for it
            jsr   FINDSYM
            bcc   :loop              ;already provided
            sec
            rts
:no         clc
            rts

*---------------------------------------------------------------
* MEMTAKE -- take this member: record its NAME and publish its
* symbols. It does NOT touch the module list -- LIBSPLICE
* places the whole take set in DIRECTORY order once the
* fixpoint settles, because discovery order depends on which
* pass found a member and put-order byte-identity cannot.
*---------------------------------------------------------------
MEMTAKE     jsr   TAKEADD
            bcs   :fail
            inc   LIBCHG
            lda   #<TAILBUF
            sta   ND_PTR
            lda   #>TAILBUF
            sta   ND_PTR+1
            jsr   SKIPFIX
:loop       jsr   SYMREC
            bcs   :done
            lda   ND_FLAG
            and   #FLAG_ENT
            beq   :isext
            jsr   ADDSYM
            bcs   :fail
            bra   :loop
:isext      lda   ND_FLAG
            and   #FLAG_EXT
            beq   :loop
            jsr   FINDSYM
            bcc   :loop
            jsr   ADDUNDEF
            bcs   :fail
            bra   :loop
:done       clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* TAKEADD -- append the member entry at ND_PTR3 ([len][name])
* to the take pool, keeping it $00-terminated.
*---------------------------------------------------------------
TAKEADD     clc
            lda   #<TAKEPOOL
            adc   TAKEUSED
            sta   ND_TMP
            lda   #>TAKEPOOL
            adc   TAKEUSED+1
            sta   ND_TMP+1
            ldy   #0
:cpy        lda   (ND_PTR3),y
            sta   (ND_TMP),y
            cpy   MEMLEN
            beq   :term
            iny
            bra   :cpy
:term       ldy   MEMLEN
            iny
            lda   #0
            sta   (ND_TMP),y
            clc
            lda   TAKEUSED
            adc   MEMLEN
            sta   TAKEUSED
            lda   TAKEUSED+1
            adc   #0
            sta   TAKEUSED+1
            inc   TAKEUSED
            bne   :nocy
            inc   TAKEUSED+1
:nocy       lda   TAKEUSED+1
            cmp   #>TAKEPLCAP
            bcs   :full
            clc
            rts
:full       jsr   ERR_LIBFULL        ;LOUD, like its UNDEF twin
            sec
            rts

*---------------------------------------------------------------
* FINDTAKE -- is the member entry at ND_PTR3 in the take pool?
* Carry clear = yes.
*---------------------------------------------------------------
FINDTAKE    lda   ND_PTR3
            clc
            adc   #1
            sta   ND_NAME
            lda   ND_PTR3+1
            adc   #0
            sta   ND_NAME+1
            lda   MEMLEN
            sta   ND_LEN
            lda   #<TAKEPOOL
            sta   ND_PTR2
            lda   #>TAKEPOOL
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
* LIBSPLICE -- after request LIBI's fixpoint settles, walk the
* member pool -- SCANLIB left the last pass's full list, which
* is DIRECTORY order -- and insert every taken member into the
* module list at the position the -l flag held on the command
* line. The fixpoint decides the SET, the directory decides the
* ORDER, the flag decides WHERE: put-order byte-identity for
* the kernel links rests on exactly this rule, and it is why
* placement is not discovery order (which varies with the pass
* that found a member).
*---------------------------------------------------------------
LIBSPLICE   ldx   LIBI
            lda   LIBPOS,x
            sta   INSAT
            stz   SPLCNT
            lda   #<MEMPOOL
            sta   ND_PTR3
            lda   #>MEMPOOL
            sta   ND_PTR3+1
:loop       ldy   #0
            lda   (ND_PTR3),y
            beq   :done
            sta   MEMLEN
            jsr   FINDTAKE
            bcs   :skip
            jsr   MEMPATH
            lda   #<MEMBUF
            sta   PTR0
            lda   #>MEMBUF
            sta   PTR0+1
            jsr   INSMOD
            bcs   :fail
            inc   INSAT
            inc   SPLCNT
:skip       lda   MEMLEN
            clc
            adc   #1
            jsr   ADVPTR3
            bra   :loop
*-- later -l flags stood after this one's insertions: shift
*-- their recorded positions by what was just spliced in.
:done       ldx   LIBI
:adj        inx
            cpx   NLIBR
            bcs   :ok
            lda   LIBPOS,x
            clc
            adc   SPLCNT
            sta   LIBPOS,x
            bra   :adj
:ok         clc
            rts
:fail       sec
            rts
