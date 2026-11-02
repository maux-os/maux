*---------------------------------------------------------------
* ldpass.s -- nld's two passes. Put first, so START is the
* entry point (nmtop.s precedent). See nld.s's header.
*---------------------------------------------------------------
START       stz   ZFLAG
            stz   OFLAG
            stz   NMODS
            stz   MODUSED
            stz   MODUSED+1
            lda   #FTYPE_BIN
            sta   OUTTYPE
            stz   NLIBD
            stz   NLIBR
            stz   LIBUSED
            stz   LIBUSED+1
            stz   UNDUSED
            stz   UNDUSED+1
            stz   UNDEFPOOL
            stz   NAMEPOOL          ;an empty pool is one $00
            stz   NAMEUSED
            stz   NAMEUSED+1
            stz   ERRFLAG
            stz   OUTOPEN
            stz   SEGADR            ;-s: no segment run yet
            stz   SEGADR+1
            stz   SEGADR2
            stz   SEGADR2+1
            stz   SEGON
*-- FLUSHZ writes -z's pending zeros from ZEROS; the arena is
*-- bss and starts as whatever the bank held
            ldx   #0
:zz         stz   ZEROS,x
            inx
            bne   :zz

*-- the link address defaults to LOAD_BASE, spelled once via the
*-- shared include; -a overrides it.
            lda   #<LOAD_BASE
            sta   LNKADDR
            lda   #>LOAD_BASE
            sta   LNKADDR+1

            jsr   ARGFILE           ;`ld @FILE` -> argv
            lda   #1
            sta   ARGI
*-- inverted and jumped: -L/-l grew the parser past an 8-bit
*-- branch's reach, the same squeeze ld.s's own arg loop hit.
:argloop    lda   ARGI
            cmp   ARGC
            bcc   :argmore2
            jmp   :argsdone
:argmore2   jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD              ;'-' high-bit
            beq   :isflag
            jmp   :ispath
:isflag     iny
            lda   (PTR0),y
            cmp   #$FA              ;'z'
            beq   :isZ
            cmp   #$EF              ;'o'
            bne   :notO
            jmp   :isO
:notO
            cmp   #$E1              ;'a'
            beq   :isA
            cmp   #$F4              ;'t'
            beq   :isT
            cmp   #$CC              ;'L'
            beq   :isBigL
            cmp   #$EC              ;'l'
            beq   :isLittleL
            cmp   #$F3              ;'s'
            bne   :notS
            jmp   :isS
:notS       jmp   USAGE
*-- -t sets the OUTPUT's ProDOS file type, default $06 (BIN).
*-- `-t FF -a 2000` is what makes a .SYSTEM file: ProDOS's
*-- loader wants type $FF loaded at $2000, and the link address
*-- already lands in aux, so the two flags say the whole thing.
:isT        iny
            lda   (PTR0),y
            bne   :toUSAGE
            jsr   NEXTARG
            bcs   :toUSAGE
            jsr   PARSEHEX
            bcs   :toUSAGE
            lda   HEXVAL
            sta   OUTTYPE
            bra   :argnext
*-- THE PATH MAY BE ATTACHED -- `-L/usr/lib/LIBK`, not just
*-- `-L /usr/lib/LIBK` -- same reason and same idiom as `-s`'s
*-- own attached form below: the guest shell's MAXARGV is 32,
*-- and a generated kernel link line names its modules bare
*-- (2026-09-25, docs/LD-NATIVE.md sec 2b) specifically to stay
*-- under it -- `-L` at two tokens instead of one put playtest's
*-- own line at exactly 32, one over. Both spellings resolve to
*-- the same ADDLIBD call.
:isBigL     iny
            lda   (PTR0),y
            beq   :LSEP
            clc                     ;attached: step past "-L"
            lda   PTR0
            adc   #2
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            bra   :LHAVE
:LSEP       jsr   NEXTARG
            bcs   :toUSAGE
:LHAVE      jsr   ADDLIBD
            bcs   :toUSAGE
            bra   :argnext
:isLittleL  iny
            lda   (PTR0),y
            bne   :toUSAGE
            jsr   NEXTARG
            bcs   :toUSAGE
            jsr   ADDLIBR
            bcs   :toUSAGE
            bra   :argnext
:isZ        iny
            lda   (PTR0),y
            bne   :toUSAGE
            lda   #1
            sta   ZFLAG
            bra   :argnext
:toUSAGE    jmp   USAGE
:isA        iny
            lda   (PTR0),y
            bne   :toUSAGE
            jsr   NEXTARG
            bcs   :toUSAGE
            jsr   PARSEHEX
            bcs   :toUSAGE
            lda   HEXVAL
            sta   LNKADDR
            lda   HEXVAL+1
            sta   LNKADDR+1
            bra   :argnext
:isO        iny
            lda   (PTR0),y
            bne   :toUSAGE
            jsr   NEXTARG
            bcs   :toUSAGE
            lda   PTR0
            sta   OBJPTR
            lda   PTR0+1
            sta   OBJPTR+1
            lda   #1
            sta   OFLAG
            bra   :argnext
:ispath     jsr   ADDMOD
            bcs   :toUSAGE
:argnext    inc   ARGI
            jmp   :argloop
*-- -s adr -- base the modules that follow at adr while the
*-- file offset keeps running (ld.s's SEGADR comment); -s 0
*-- ends the run. It sits AFTER `:argnext`'s own `jmp`, where
*-- nothing falls through, precisely so that adding it does not
*-- lengthen any other handler's `bra :argnext` -- the first
*-- placement, before `:isT`, pushed two of them out of range.
*--
*-- THE ADDRESS MAY BE ATTACHED -- `-sE000`, not just `-s E000`
*-- -- and that is not sprawl for its own sake: the guest shell
*-- that runs the generated link lines has MAXARGV 32, and sh's
*-- own link needs its segment bracket to cost two tokens
*-- rather than four (scripts/build_nas_librel_image.py's
*-- `ntok`). Both spellings parse to the same HEXVAL.
:isS        iny
            lda   (PTR0),y
            beq   :sSEP
            clc                     ;attached: step past "-s"
            lda   PTR0
            adc   #2
            sta   PTR0
            lda   PTR0+1
            adc   #0
            sta   PTR0+1
            bra   :sHEX
:sSEP       jsr   NEXTARG
            bcs   :sUSAGE
:sHEX       jsr   PARSEHEX
            bcs   :sUSAGE
            lda   HEXVAL
            ora   HEXVAL+1
            beq   :segoff
*-- two runs only: a third nonzero -s has no cursor of its own
*-- and would mis-link every module after it
            lda   SEGADR
            ora   SEGADR+1
            bne   :second
            lda   HEXVAL
            sta   SEGADR
            lda   HEXVAL+1
            sta   SEGADR+1
            lda   #1
            sta   SEGON
            jmp   :argnext
:second     lda   SEGADR2
            ora   SEGADR2+1
            bne   :sUSAGE
            lda   HEXVAL
            sta   SEGADR2
            lda   HEXVAL+1
            sta   SEGADR2+1
            lda   #2
            sta   SEGON
            jmp   :argnext
:segoff     stz   SEGON
            jmp   :argnext
:sUSAGE     jmp   USAGE
:argsdone   lda   NMODS
            bne   :havemods
            jmp   USAGE
:havemods   lda   OFLAG
            bne   :haveout
            jmp   USAGE
:haveout    jsr   LIBRESOLVE
            bcs   :die
            jsr   PASS1
            bcs   :die
            jsr   OPENOUT
            bcs   :die
            jsr   PASS2
            bcs   :dieout
            jsr   FINISHOUT
            bcs   :dieout
            lda   #0
            jsr   EXIT
*-- a pass-2 refusal leaves no output behind (ABORTOUT destroys
*-- the partial file): a failed link must not look linked
:dieout     jsr   ABORTOUT
:die        lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* NEXTARG -- step to the next argv word and fetch it into PTR0.
* Carry set if there is no next word (a flag wanting an operand
* at the end of the line).
*---------------------------------------------------------------
NEXTARG     lda   ARGI
            clc
            adc   #1
            cmp   ARGC
            bcs   :none
            sta   ARGI
            jsr   GETARG
            clc
            rts
:none       sec
            rts

*---------------------------------------------------------------
* ADDMOD -- append the path at PTR0 to the module list.
*
* Modules are held as PATH STRINGS in a pool, not as argv
* indices, because a library member pulled in by -l is not an
* argv word at all and the two must share one representation.
* MODOFF_L/H index the pool; the strings are liba's high-bit
* form throughout, which is what MKPATH expects.
*---------------------------------------------------------------
ADDMOD      lda   NMODS
            cmp   #MODMAX
            bcs   :full
            ldx   NMODS
*-- -s: remember, PER MODULE, whether this operand was named
*-- inside a segment run. Per module and not "from index N on"
*-- because -l splices members into the list (INSMOD) and
*-- every index after the splice point moves.
            lda   SEGON             ;0 flat, 1 or 2 = the run
            sta   SEGFLG,x
            lda   MODUSED
            sta   MODOFF_L,x
            lda   MODUSED+1
            sta   MODOFF_H,x
            clc
            lda   #<MODPOOL
            adc   MODUSED
            sta   ND_TMP
            lda   #>MODPOOL
            adc   MODUSED+1
            sta   ND_TMP+1
            ldy   #0
:cpy        lda   (PTR0),y
            sta   (ND_TMP),y
            beq   :cpydone
            iny
            cpy   #64
            bcc   :cpy
:full       sec
            rts
:cpydone    iny
            clc
            tya
            adc   MODUSED
            sta   MODUSED
            lda   MODUSED+1
            adc   #0
            sta   MODUSED+1
            cmp   #>MODPLCAP
            bcs   :full
            inc   NMODS
            clc
            rts

*---------------------------------------------------------------
* INSMOD -- insert the path at PTR0 into the module list at
* index INSAT, shifting later entries up one. Only MODOFF_L/H
* carry the list's order -- the pool itself is append-only, so
* the copy is ADDMOD's.
*---------------------------------------------------------------
INSMOD      lda   NMODS
            cmp   #MODMAX
            bcs   :full
            ldx   NMODS
:shift      cpx   INSAT
            beq   :place
            lda   MODOFF_L-1,x
            sta   MODOFF_L,x
            lda   MODOFF_H-1,x
            sta   MODOFF_H,x
            lda   SEGFLG-1,x
            sta   SEGFLG,x
            dex
            bra   :shift
:place      stz   SEGFLG,x          ;-l members link flat
            lda   MODUSED
            sta   MODOFF_L,x
            lda   MODUSED+1
            sta   MODOFF_H,x
            clc
            lda   #<MODPOOL
            adc   MODUSED
            sta   ND_TMP
            lda   #>MODPOOL
            adc   MODUSED+1
            sta   ND_TMP+1
            ldy   #0
:cpy        lda   (PTR0),y
            sta   (ND_TMP),y
            beq   :cpydone
            iny
            cpy   #64
            bcc   :cpy
:full       sec
            rts
:cpydone    iny
            clc
            tya
            adc   MODUSED
            sta   MODUSED
            lda   MODUSED+1
            adc   #0
            sta   MODUSED+1
            cmp   #>MODPLCAP
            bcs   :full
            inc   NMODS
            clc
            rts

*---------------------------------------------------------------
* MODPTR -- point PTR0 at module ND_I's path in the pool.
*---------------------------------------------------------------
MODPTR      ldx   ND_I
            clc
            lda   #<MODPOOL
            adc   MODOFF_L,x
            sta   PTR0
            lda   #>MODPOOL
            adc   MODOFF_H,x
            sta   PTR0+1
            rts

*---------------------------------------------------------------
* OPENMOD -- open module ND_I and read its code length.
* IN:  ND_I = module index
* OUT: carry clear, MODFD open, ND_CODE = code length.
* The AUX TYPE *is* the code length (docs/REL-FORMAT.md); it is
* read from the directory entry, never guessed from the file.
*
* -L RESOLUTION (2026-09-25, docs/LD-NATIVE.md sec 2b): an
* explicit module operand used to open only the path it was
* given, verbatim -- every -l member already resolves against
* -L (ldlib.s LIBDIRFOR), but a bare module name never did, so a
* generated link line had to spell out a full path per module.
* Tries each -L directory, in COMMAND-LINE ORDER, the SAME order
* and the SAME reasoning `-l` already uses (LIBDIRFOR: try each
* -L in turn, first hit wins) -- one search-order convention for
* the whole linker, not two. Falls back to the ORIGINAL as-is
* resolution, unconditionally, if nothing in -L matched, so a
* module that happens to share a name with something in a -L
* directory but is not actually there still resolves the old
* way.
*
* SKIPPED ENTIRELY, BY CONSTRUCTION, when there is nothing to
* try (NLIBD=0) or when the name is a real PATH (contains "/")
* -- an explicit path is never search-relative, same convention
* Unix `ld` uses and the same one this file's own MKPATH already
* applies to a leading "." -- so every invocation that supplies
* no -L, and every module operand with a "/" in it regardless of
* -L, takes the EXACT same instruction path as before this
* existed. That is what makes constraint 2 (docs/LD-NATIVE.md,
* NOTES-BYE.md) true by construction rather than by testing it.
*
* COST, MEASURED IN SC_GFI CALLS (the real expense -- directory
* I/O, not the cheap in-memory compose): a HIT on the first -L
* directory costs exactly ONE SC_GFI, identical to the old
* as-is-only code -- zero overhead on the path nas-librel-image
* actually exercises (one -L directory, every kernel module
* lives there). A MISS costs one FAILED SC_GFI per -L directory
* tried (up to LIBDMAX = 4) before the as-is fallback's own
* SC_GFI -- a real, non-trivial cost for a module that does NOT
* live under any -L path, not a rounding error, and named here
* rather than hidden in the code.
*---------------------------------------------------------------
OPENMOD     jsr   MODPTR
            lda   PTR0
            sta   MODNAMEP
            lda   PTR0+1
            sta   MODNAMEP+1
            lda   NLIBD
            beq   :asis
            jsr   HASSLASH
            bcs   :asis             ;carry set = contains "/"
            stz   LIBD
:ltry       lda   LIBD
            cmp   NLIBD
            bcs   :asis             ;exhausted -L, fall back
            ldx   LIBD
            clc
            lda   #<LIBPOOL
            adc   LIBDOF_L,x
            sta   PTR0
            lda   #>LIBPOOL
            adc   LIBDOF_H,x
            sta   PTR0+1
            jsr   MODCOMPOSE        ;LIBDBUF = -L dir+"/"+name
            lda   #<LIBDBUF
            sta   PTR0
            lda   #>LIBDBUF
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcc   :havegfi
            inc   LIBD
            bra   :ltry
:asis       lda   MODNAMEP
            sta   PTR0
            lda   MODNAMEP+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<GFIPARM
            ldx   #>GFIPARM
            jsr   SC_GFI
            bcs   :fail
:havegfi
*-- CONFIRM IT IS A MERLIN REL OBJECT. The AUX TYPE is read as a
*-- code length, and every file has one -- so without this a
*-- text file or a stray binary is linked as though its aux
*-- meant something, the quietest way to a wrong image.
            lda   GFIPARM_TYPE
            cmp   #FTYPE_RELM
            bne   :badtype
            lda   GFIPARM_AUX
            sta   ND_CODE
            lda   GFIPARM_AUX+1
            sta   ND_CODE+1
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   OPARM_REF
            sta   MODFD
            clc
            rts
:fail       jsr   ERR_OPEN
            sec
            rts
:badtype    jsr   ERR_TYPE
            sec
            rts

*---------------------------------------------------------------
* HASSLASH -- IN: PTR0 = NUL-terminated liba (high-bit) string.
* OUT: carry SET if it contains "/" anywhere in its first 64
* characters (ADDMOD's own module-name pool cap, ldpass.s) --
* an explicit path, same convention Unix `ld` uses, is never
* -L search-relative. Carry clear if none found (or NUL first).
*---------------------------------------------------------------
HASSLASH    ldy   #0
:loop       lda   (PTR0),y
            beq   :no
            cmp   #"/"
            beq   :yes
            iny
            cpy   #65
            bcc   :loop
:no         clc
            rts
:yes        sec
            rts

*---------------------------------------------------------------
* CLOSEMOD -- close MODFD.
*---------------------------------------------------------------
CLOSEMOD    lda   MODFD
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jmp   SC_CLOSE

*---------------------------------------------------------------
* SEEKMOD -- position MODFD at the 16-bit offset in ND_TMP.
* Uses liba's LSEEK rather than a private SET_MARK parmlist:
* the mark is 24-bit and LSEEK already owns that arithmetic.
* It OVERWRITES the 3 bytes at (PTR0) with the resulting mark,
* which is why SEEKPOS is a scratch cell and not ND_TMP.
*---------------------------------------------------------------
SEEKMOD     lda   ND_TMP
            sta   SEEKPOS
            lda   ND_TMP+1
            sta   SEEKPOS+1
            stz   SEEKPOS+2
            lda   #<SEEKPOS
            sta   PTR0
            lda   #>SEEKPOS
            sta   PTR0+1
            ldy   #SEEK_SET
            lda   MODFD
            jmp   LSEEK

*---------------------------------------------------------------
* READTAIL -- seek past the code and read the fixup+symbol tail
* into TAILBUF. OUT: TAILLEN, and ND_END = TAILBUF+TAILLEN.
*---------------------------------------------------------------
READTAIL    lda   ND_CODE
            sta   ND_TMP
            lda   ND_CODE+1
            sta   ND_TMP+1
            jsr   SEEKMOD
            bcs   :fail
            lda   MODFD
            sta   RPARM_REF
            lda   #<TAILBUF
            sta   RPARM_BUF
            lda   #>TAILBUF
            sta   RPARM_BUF+1
            lda   #<TAILCAP
            sta   RPARM_REQ
            lda   #>TAILCAP
            sta   RPARM_REQ+1
            lda   #<RPARM
            ldx   #>RPARM
            jsr   SC_READ
            bcs   :fail
            lda   RPARM_TRN
            sta   TAILLEN
            lda   RPARM_TRN+1
            sta   TAILLEN+1
*-- a tail that exactly fills TAILBUF is indistinguishable from
*-- one that was truncated, and a truncated dictionary links
*-- silently wrong. Refuse instead.
            lda   TAILLEN
            cmp   #<TAILCAP
            bne   :ok
            lda   TAILLEN+1
            cmp   #>TAILCAP
            beq   :toobig
:ok         clc
            lda   TAILLEN
            adc   #<TAILBUF
            sta   ND_END
            lda   TAILLEN+1
            adc   #>TAILBUF
            sta   ND_END+1
            clc
            rts
:toobig     jsr   ERR_BIG
            sec
            rts
:fail       sec
            rts
