*---------------------------------------------------------------
* asdiag.s -- DIAG2 and friends -- diagnostic printing.
* SPLIT OUT of as.s 2026-09-01 (S9-PLAN 6b stage C): the
* resident main was 21,768 B stripped against as's own
* 16,126 B source window, so it could not assemble itself.
* Body put, same module -- put in place, no byte moves.
* Cut at zone-safe global-label boundaries (scan-verified).
*---------------------------------------------------------------
* DIAG2 -- IN A/X=<//> a pointer CELL (e.g. SRCPTR/OBJPTR, 2
* bytes) holding a liba string pointer; DG_SUFLO/HI (set by the
* caller first) =<//> a suffix message. Prints
* "as: " + *that string* + *suffix* + CR.
* Both: exit status is the CALLER's job (see every call site).
*---------------------------------------------------------------
DIAG1       sta   DG_MSGLO
            stx   DG_MSGHI
            jsr   DIAG1PFX
            lda   DG_MSGLO
            sta   PTR0
            lda   DG_MSGHI
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            bra   DIAGCR

DIAG2       sta   PTR1
            stx   PTR1+1
            jsr   DIAG1PFX
            ldy   #0
            lda   (PTR1),y
            sta   PTR0
            iny
            lda   (PTR1),y
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   DG_SUFLO
            sta   PTR0
            lda   DG_SUFHI
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            bra   DIAGCR

DIAG1PFX    lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            rts

DIAGCR      lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* Data.
*---------------------------------------------------------------
USAGEMSG    asc   "usage: as [-l] [-o objfile] srcfile"
            dfb   $8D,0
ERRPFX      asc   "as: "
            dfb   0
CANTOSUF    asc   ": cannot open"
            dfb   0
WRFAILSUF   asc   ": write failed"
            dfb   0
TOOBIG      asc   "source too large"
            dfb   0
ASMFAIL     asc   "assembly error(s)"
            dfb   0
OBJBIG      asc   "object ends past $BF00"
            dfb   0
NOEXIT      asc   "internal: ASEXIT not found"
            dfb   0

LFLAG       ds    1
OFLAG       ds    1
SRCSEEN     ds    1
ARGI        ds    1
SRCPTR      ds    2
OBJPTR      ds    2
DSTFD       ds    1
ENDSRCLO    ds    1
ENDSRCHI    ds    1
CPLEN       ds    2
SCANEND     ds    2
ASEXITAD    ds    2
FE_LO       ds    1
FE_HI       ds    1
DG_MSGLO    ds    1
DG_MSGHI    ds    1
DG_SUFLO    ds    1
DG_SUFHI    ds    1
SAVOBJPNT   ds    2      ;WRITEOBJ's Z_OBJPNT copy -- liba's
                         ;PTR1/PTR2 ($E2/$E4) overwrite it
SAVOBLEN    ds    2

PATHBUF     ds    65

OPARM       dfb   PCOUNT_OPEN
OPARM_PATH  da    PATHBUF
OPARM_IOBF  da    $0000          ;kernel-owned -- see
                                 ;docs/USERLAND.md
OPARM_REF   dfb   0

RPARM       dfb   PCOUNT_READ
RPARM_REF   dfb   0
RPARM_BUF   da    0              ;runtime -- repointed from
                                 ;PTR0 every :rdloop iteration
                                 ;(RDXFORM keeps the destination
                                 ;in PTR0; the transform is
                                 ;(PTR0),y). Said PTR2 until
                                 ;2026-08-28 -- it never was.
RPARM_REQ   da    RD_CHUNK       ;runtime -- RDXFORM clamps this
                                 ;to the room left below
                                 ;RDX_BOUND on every iteration
RPARM_TRANS da    0

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

CRPARM        dfb   PCOUNT_CREATE
CRPARM_PATH   da    PATHBUF
CRPARM_ACCESS dfb   ACCESS_UNLKD
CRPARM_TYPE   dfb   FTYPE_BIN
CRPARM_AUX    da    0
CRPARM_STORE  dfb   STYP_SEEDLING
CRPARM_CDATE  da    0
CRPARM_CTIME  da    0

DOPARM      dfb   PCOUNT_OPEN
DOPARM_PATH da    PATHBUF
DOPARM_IOBF da    $0000
DOPARM_REF  dfb   0

WPARM       dfb   PCOUNT_WRITE
WPARM_REF   dfb   0
WPARM_BUF   da    0
WPARM_REQ   da    0
WPARM_TRANS da    0

C2PARM      dfb   PCOUNT_CLOSE
C2PARM_REF  dfb   0

*---------------------------------------------------------------
* Embedded blobs -- each assembled SEPARATELY at its real target
* address (build/ascore-warm-bank1.obj, build/ascore-warm-as.obj
* by check-ascore-warm's artifact phase; build/as-stubs.bin by
* src/bin/asrom.s), so a verbatim copy at startup (above) is
* correct with no relocation. NO PAD before this point (task #8
* phase D, docs/STICKY.md sec 31's cure): SYMADR now lives ABOVE
* the whole image (this file's own header MEMORY LAYOUT table),
* so nothing forces the blobs to start on a page boundary any
* more -- they pack immediately after the front-end code/data
* above. THESE BYTES ARE READ-ONLY FOR THE WHOLE RUN,
* deliberately, same as ld.s's own identical blobs: this is
* `as`'s only copy of the core, and a warm respawn hands it back
* instead of reloading it, so anything that writes here breaks
* the NEXT invocation, not this one. See the ZEROFILL call
* site's own comment (above, "the embed the core" section) for
* the invariant this replaced and why.
*
* WARM core, neither of check-ascore's two artifacts (docs/
* AS-DESIGN.md section 13, ruling 2, extended task #8 phase D):
* build/ascore-*.obj (no variant name) is check-ascore's own
* HARDWARE artifact -- P1+P4+P5+P7 only, PUTBYT's WRITE.AUX/
* WRITE.MAIN bracket still intact, correct for a real Apple's
* RAMWRT-off-by-default. A maux process's kernel baseline is
* RAMWRT-on-aux by default (this file's own header, "ALTZP
* resolution") -- the OPPOSITE default -- so embedding the
* hardware artifact here would reproduce bug 4 (PUTBYT stranding
* the symtab's "done" flag in main once RAMWRT flips to main
* after the last object byte and never flips back). NOR
* build/ascore-process-*.obj -- that pair is `ld.s`'s own embed
* (SYMADR=$2000, LINKER's own dictionary free ride, docs/
* STICKY.md sec 31) and must not move. build/ascore-warm-*.obj
* is P1w+P4+P5+P7+P10+P14 (src/merlin/patches.py's WARM_GROUPS):
* P10 removes the RAMRD/RAMWRT brackets the embedded chain still
* had (docs/AS-P10-ENUMERATION.txt), so this core never touches
* the switch at all and simply uses whatever bank is already
