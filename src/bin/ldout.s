*---------------------------------------------------------------
* ldout.s -- ld's output writer, hex parsing and diagnostics.
* Split from ldpass2.s at MAKEFILE for check-dialect's window:
* `as` charges resident + LARGEST single put, so the lever is
* always the biggest file, not the total.
*---------------------------------------------------------------
*---------------------------------------------------------------
* MAKEFILE -- create the output as a BIN file whose AUX TYPE is
* the link address (the honour-aux convention, producer side --
* S9-PLAN sec 6 L3b). An existing file is fine: $47 means it is
* already there, and a real path fault resurfaces at the OPEN.
*---------------------------------------------------------------
MAKEFILE    lda   OUTTYPE
            sta   OCRPARM_TYPE
            lda   LNKADDR
            sta   OCRPARM_AUX
            lda   LNKADDR+1
            sta   OCRPARM_AUX+1
            lda   #<OCRPARM
            ldx   #>OCRPARM
            jsr   SC_CREAT
            clc
            rts

*---------------------------------------------------------------
* PARSEHEX -- PTR0's high-bit hex string -> HEXVAL. Carry set on
* an empty or non-hex operand. It writes a SCRATCH cell, not
* LNKADDR, because -a and -t both use it and a routine that
* writes one caller's destination cannot serve the other.
*---------------------------------------------------------------
PARSEHEX    stz   HEXVAL
            stz   HEXVAL+1
            ldy   #0
            lda   (PTR0),y
            beq   :bad
:loop       lda   (PTR0),y
            beq   :done
            and   #$7F
            jsr   HEXDIG
            bcs   :bad
            pha
            lda   HEXVAL+1
            asl   HEXVAL
            rol   a
            asl   HEXVAL
            rol   a
            asl   HEXVAL
            rol   a
            asl   HEXVAL
            rol   a
            sta   HEXVAL+1
            pla
            ora   HEXVAL
            sta   HEXVAL
            iny
            bra   :loop
:done       clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* HEXDIG -- ASCII in A -> 0..15, carry set if not a hex digit.
*---------------------------------------------------------------
HEXDIG      cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :alpha
            sec
            sbc   #'0'
            clc
            rts
:alpha      and   #$DF               ;fold to upper case
            cmp   #'A'
            bcc   :bad
            cmp   #'F'+1
            bcs   :bad
            sec
            sbc   #'A'-10
            clc
            rts
:bad        sec
            rts

*---------------------------------------------------------------
* Diagnostics. They say "ld: ", not "nld: ": this file IS `ld`
* once it passes, the prefix is what users and check-ld both
* read, and a message that renames itself on promotion is a
* message someone greps for and does not find.
*---------------------------------------------------------------
DIAG        ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            sta   ERRFLAG
            rts

SAY         sta   PTR0
            stx   PTR0+1
            jmp   DIAG

*---------------------------------------------------------------
* SAYWHAT -- "<message> <name>", the form every diagnostic here
* should have had from the start. A bare `ld: undefined symbol`
* does not say WHICH, and `ld: cannot open module` does not say
* which module, so the reader goes looking through the link line
* by hand. Everything needed is already in scope at each site:
* the path in MODPOOL, the symbol in ND_NAME/ND_LEN.
* IN: A/X = message, PTR1 = a NUL-terminated high-bit string.
*---------------------------------------------------------------
SAYWHAT     sta   PTR0
            stx   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #" "
            ldx   #FD_STDERR
            jsr   PUTC
            lda   PTR1
            sta   PTR0
            lda   PTR1+1
            sta   PTR0+1
            jmp   DIAG

*---------------------------------------------------------------
* SYMBUF -- copy the symbol at ND_NAME/ND_LEN into NAMEBUF as a
* NUL-terminated liba string. REL symbol names are RAW 7-BIT
* (src/bin/nm.s's header says so and it is right), while liba's
* string routines want the high bit set -- so printing the name
* straight out of the dictionary emits control characters.
*---------------------------------------------------------------
SYMBUF      ldy   #0
:loop       cpy   ND_LEN
            beq   :done
            cpy   #15
            bcs   :done
            lda   (ND_NAME),y
            ora   #$80
            sta   NAMEBUF,y
            iny
            bra   :loop
:done       lda   #0
            sta   NAMEBUF,y
            lda   #<NAMEBUF
            sta   PTR1
            lda   #>NAMEBUF
            sta   PTR1+1
            rts

*---------------------------------------------------------------
* MODNAME -- point PTR1 at the current module's path.
*---------------------------------------------------------------
MODNAME     jsr   MODPTR
            lda   PTR0
            sta   PTR1
            lda   PTR0+1
            sta   PTR1+1
            rts

ERR_OPEN    jsr   MODNAME
            lda   #<M_OPEN
            ldx   #>M_OPEN
            jmp   SAYWHAT
ERR_BIG     jsr   MODNAME
            lda   #<M_BIG
            ldx   #>M_BIG
            jmp   SAYWHAT
ERR_TYPE    jsr   MODNAME
            lda   #<M_TYPE
            ldx   #>M_TYPE
            jmp   SAYWHAT
ERR_REFNUM  jsr   MODNAME
            lda   #<M_REFNUM
            ldx   #>M_REFNUM
            jmp   SAYWHAT
ERR_KIND    jsr   MODNAME
            lda   #<M_KIND
            ldx   #>M_KIND
            jmp   SAYWHAT
ERR_UNDEF   jsr   SYMBUF
            lda   #<M_UNDEF
            ldx   #>M_UNDEF
            jmp   SAYWHAT
ERR_DUP     jsr   SYMBUF
            lda   #<M_DUP
            ldx   #>M_DUP
            jmp   SAYWHAT
ERR_NOLIB   lda   #<LIBDBUF
            sta   PTR1
            lda   #>LIBDBUF
            sta   PTR1+1
            lda   #<M_NOLIB
            ldx   #>M_NOLIB
            jmp   SAYWHAT
ERR_LIBFULL lda   #<LIBDBUF
            sta   PTR1
            lda   #>LIBDBUF
            sta   PTR1+1
            lda   #<M_LIBFULL
            ldx   #>M_LIBFULL
            jmp   SAYWHAT
ERR_SYMS    lda   #<M_SYMS
            ldx   #>M_SYMS
            jmp   SAY
ERR_ORDER   jsr   MODNAME
            lda   #<M_ORDER
            ldx   #>M_ORDER
            jmp   SAYWHAT
ERR_FIXOFF  jsr   MODNAME
            lda   #<M_FIXOFF
            ldx   #>M_FIXOFF
            jmp   SAYWHAT
ERR_SHORT   jsr   MODNAME
            lda   #<M_SHORT
            ldx   #>M_SHORT
            jmp   SAYWHAT
ERR_WRITE   lda   #<M_WRITE
            ldx   #>M_WRITE
            jmp   SAY

USAGE       lda   #<M_USAGE
            ldx   #>M_USAGE
            jsr   SAY
            lda   #2
            jsr   EXIT

DEFOUT      asc   "LDOUT"
            dfb   0
M_USAGE     asc   "usage: ld [-a adr] [-z] [-t typ] [-o out]"
            dfb   $8D
            asc   "       [-s adr] [-L dir] [-l lib] module ..."
            dfb   $8D
            asc   "   or: ld @file"
            dfb   0
M_OPEN      asc   "ld: cannot open module"
            dfb   0
M_BIG       asc   "ld: dictionary too large"
            dfb   0
M_SYMS      asc   "ld: too many symbols"
            dfb   0
M_UNDEF     asc   "ld: undefined symbol"
            dfb   0
M_KIND      asc   "ld: unknown fixup kind"
            dfb   0
M_ORDER     asc   "ld: fixups out of order in"
            dfb   0
M_FIXOFF    asc   "ld: fixup outside module"
            dfb   0
M_SHORT     asc   "ld: module shorter than its aux"
            dfb   0
M_WRITE     asc   "ld: write failed"
            dfb   0
M_REFNUM    asc   "ld: refnum out of range"
            dfb   0
M_NOLIB     asc   "ld: cannot open library"
            dfb   0
M_LIBFULL   asc   "ld: too many members in"
            dfb   0
M_DUP       asc   "ld: duplicate symbol"
            dfb   0
M_TYPE      asc   "ld: not a Merlin REL object"
            dfb   0
*-- the built-in library search path, tried after every -L.
*-- `-l c` looks for <dir>/LIBC, the ProDOS-shaped spelling of
*-- Unix's libc.a -- a DIRECTORY of REL objects, because ProDOS
*-- directories already are an archive format.
DEFLIB      asc   "/usr/lib"
            dfb   0

*-- MLI parameter blocks
GFIPARM      dfb   PCOUNT_GFI
GFIPARM_PATH da    PATHBUF
GFIPARM_ACC  dfb   0
GFIPARM_TYPE dfb   0
GFIPARM_AUX  da    0
GFIPARM_STOR dfb   0
GFIPARM_BLKS da    0
GFIPARM_MDAT da    0
GFIPARM_MTIM da    0
GFIPARM_CDAT da    0
GFIPARM_CTIM da    0

OPARM        dfb   PCOUNT_OPEN
OPARM_PATH   da    PATHBUF
OPARM_IOBUF  da    $0000
OPARM_REF    dfb   0

RPARM        dfb   PCOUNT_READ
RPARM_REF    dfb   0
RPARM_BUF    da    0
RPARM_REQ    da    0
RPARM_TRN    da    0

WPARM        dfb   PCOUNT_WRITE
WPARM_REF    dfb   0
WPARM_BUF    da    0
WPARM_REQ    da    0
WPARM_TRN    da    0

CPARM        dfb   PCOUNT_CLOSE
CPARM_REF    dfb   0

DPARM        dfb   PCNT_DESTROY
DPARM_PATH   da    PATHBUF

OCRPARM      dfb   PCOUNT_CREATE
OCRPARM_PATH da    PATHBUF
OCRPARM_ACC  dfb   ACCESS_UNLKD
OCRPARM_TYPE dfb   FTYPE_BIN
OCRPARM_AUX  da    0
OCRPARM_STOR dfb   STYP_SEEDLING
OCRPARM_CDAT da    0
OCRPARM_CTIM da    0
