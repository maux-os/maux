*---------------------------------------------------------------
* asboot.s -- BLOBSIG + startup blob copy-out.
* SPLIT OUT of as.s 2026-09-01 (S9-PLAN 6b stage C): the
* resident main was 21,768 B stripped against as's own
* 16,126 B source window, so it could not assemble itself.
* Body put, same module -- put in place, no byte moves.
* Cut at zone-safe global-label boundaries (scan-verified).
*---------------------------------------------------------------
* BLOBSIG -- the first three bytes of the embedded core AS THIS
* RUN FOUND THEM, captured before anything below could touch
* them. PREEXIT's own CHKBLOB re-reads them at every exit; see
* that routine's own header (transplanted from ld.s's identical
* shape, docs/STICKY.md sec 31).
START       lda   CORE_BANK1
            sta   BLOBSIG
            lda   CORE_BANK1+1
            sta   BLOBSIG+1
            lda   CORE_BANK1+2
            sta   BLOBSIG+2
            stz   LFLAG
            stz   OFLAG
            stz   SRCSEEN
            lda   #1
            sta   ARGI
:argloop    lda   ARGI
            cmp   ARGC
            bcs   :argsdone
            jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD              ;'-' high-bit
            bne   :isPath
            iny
            lda   (PTR0),y
            cmp   #$EC              ;'l' high-bit
            beq   :optL
            cmp   #$EF              ;'o' high-bit
            beq   :optO
            jmp   USAGE
:optL       iny
            lda   (PTR0),y
            bne   USAGE             ;must be exactly "-l"
            lda   #1
            sta   LFLAG
            jmp   :argnext
:optO       iny
            lda   (PTR0),y
            bne   USAGE             ;must be exactly "-o"
            lda   ARGI
            clc
            adc   #1
            cmp   ARGC
            bcs   USAGE             ;no operand follows -o
            sta   ARGI
            jsr   GETARG
            lda   PTR0
            sta   OBJPTR
            lda   PTR0+1
            sta   OBJPTR+1
            lda   #1
            sta   OFLAG
            jmp   :argnext
:isPath     lda   SRCSEEN
            bne   USAGE             ;more than one bare arg
            lda   PTR0
            sta   SRCPTR
            lda   PTR0+1
            sta   SRCPTR+1
            lda   #1
            sta   SRCSEEN
:argnext    inc   ARGI
            jmp   :argloop
:argsdone   lda   SRCSEEN
            bne   :haveSrc
USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   PREEXIT

*---------------------------------------------------------------
* Open + read + transform the source into SRC_BASE, high-bit-
* set with $8D line delimiters (Merlin's own on-disk shape --
* src/merlin/patches.py's decode_lines/encode_line do the exact
* inverse). $0D/$0A each become one $8D; every other byte is
* OR'd with $80 verbatim (v1: no attempt to skip a stray high
* bit already set -- maux source files are plain low-ASCII, per
* every other util's own text-handling convention).
*
* Reads DIRECTLY into the source window (PTR2, walking forward
* from SRC_BASE) and transforms IN PLACE -- no intermediate
* staging buffer. RD_CHUNK=1024 bytes/read (docs/PROCIO.md
* section 8's ordering: "K1 first... then the `as` read-size
* fix"), up from a 64-byte CBUF this loop used to stage through:
* a 28KB module cost ~450 syscalls at 64B/read, ~28 at 1024B/
* read. Safe to read straight to the final address because the
* transform is 1-for-1 (never grows or shrinks the byte count),
* so the raw disk bytes and their translated form occupy the
* exact same offsets -- translating after the fact in place is
* equivalent to translating before the copy. Per PROCIO.md
* section 5, `as` must NOT use LC bank 1 (both its own LC banks
* already hold Merlin's code, MACED/MACEXEC/MACASS in one,
* LINKER+ASS.BNK1 in the other) -- this never touches LC at all,
* SRC_BASE is ordinary process memory in this front end's own
* main address space.
*---------------------------------------------------------------
RD_CHUNK    equ   1024
:haveSrc    lda   SRCPTR
            sta   PTR0
            lda   SRCPTR+1
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcc   :srcok
            lda   #<CANTOSUF
            sta   DG_SUFLO
            lda   #>CANTOSUF
            sta   DG_SUFHI
            lda   #<SRCPTR
            ldx   #>SRCPTR
            jsr   DIAG2
            lda   #1
            jsr   PREEXIT
:srcok      lda   OPARM_REF
            lda   #<SRC_BASE
            sta   PTR0
            lda   #>SRC_BASE
            sta   PTR0+1
*-- The read+transform loop this used to spell out inline now
*-- lives in RDXFORM below: AS_GOREAD needs the identical
*-- thing for a put file and a second copy is how the two drift.
*-- RDXFORM leaves PTR0 one past the last byte, which is exactly
*-- what ENDSRC wants.
            lda   #>HIMEM_VAL
            sta   RDX_BOUND
            lda   OPARM_REF
            jsr   RDXFORM
            bcc   :rddone
            cmp   #1
            beq   :toobigerr
            lda   #<CANTOSUF
            sta   DG_SUFLO
            lda   #>CANTOSUF
            sta   DG_SUFHI
            lda   #<SRCPTR
            ldx   #>SRCPTR
            jsr   DIAG2
            lda   #1
            jsr   PREEXIT
:toobigerr  lda   #<TOOBIG
            ldx   #>TOOBIG
            jsr   DIAG1
            lda   #1
            jsr   PREEXIT
:rddone     lda   RDX_FD           ;RDXFORM parked it
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            lda   PTR0
            sta   ENDSRCLO
            lda   PTR0+1
            sta   ENDSRCHI

*---------------------------------------------------------------
* Embed the core: LC write-enable, then three verbatim byte
* copies (each blob was assembled AT its real target address,
* so no relocation math -- see the file header). Then scan for
* ASEXIT's self-jump and poke this front end's own exit in over
* it (P5's landing pad; see docs/AS-DESIGN.md's own open risk --
* the address is discovered fresh every run, never hardcoded).
*---------------------------------------------------------------
* NOTE on the bank name mismatch (checked, then reverted --
* recorded so the next reader doesn't repeat the detour):
* MACASS.S's ASM entry (`JSR BNK1`, its first instruction) does
* `BIT CONTROL!BANK1!ENABLE` = BIT ($C080|$08|$03) = BIT $C08B
* -- Merlin's OWN "BANK1" name for that switch. That is the
* SAME physical address as memmap.equ's LCBANK2_RAM ($C08B) --
* the two codebases' bank-1/bank-2 NAMES are swapped relative
* to each other (a real, documented Apple II LC naming
* inversion), but the ADDRESS matches, so LCBANK2_RAM here is
* correct and matches what ASM_ENTRY's own JSR BNK1 selects.
            lda   LCBANK2_RAM        ;write-enable, double read
            lda   LCBANK2_RAM        ;(house idiom, src/kernel/
                                     ;timer.s procspawn.s)
            lda   #<CORE_BANK1
            sta   PTR0
            lda   #>CORE_BANK1
            sta   PTR0+1
            lda   #<CORE_D000
            sta   PTR1
            lda   #>CORE_D000
            sta   PTR1+1
            lda   #<CORE_B1_LEN
            sta   CPLEN
            lda   #>CORE_B1_LEN
            sta   CPLEN+1
            jsr   BLOCKCP

            lda   #<CORE_AS
            sta   PTR0
            lda   #>CORE_AS
            sta   PTR0+1
            lda   #<CORE_E5F0
            sta   PTR1
            lda   #>CORE_E5F0
            sta   PTR1+1
            lda   #<CORE_AS_LEN
            sta   CPLEN
            lda   #>CORE_AS_LEN
            sta   CPLEN+1
            jsr   BLOCKCP

            lda   #<STUBBLOB
            sta   PTR0
            lda   #>STUBBLOB
            sta   PTR0+1
            lda   #<STUB_FCA8
            sta   PTR1
            lda   #>STUB_FCA8
            sta   PTR1+1
            lda   #<STUB_LEN
            sta   CPLEN
            lda   #>STUB_LEN
            sta   CPLEN+1
            jsr   BLOCKCP

* SYMADR MUST start genuinely zero -- ASS.BNK1.S's GTLEN end-of-
* symbol-table check trusts a zero byte one past the last real
* entry to mean "no more symbols," and SYMPRINT's alphabetical/
* numerical listing walk (reached on EVERY assembly, error or
* not -- GETLINE.S DONE always falls through it) relies on that.
*
* TASK #8 PHASE D (docs/STICKY.md sec 31's cure, applied to
* `as` -- REPLACES the original invariant this comment used to
* describe, kept here for the next reader's own postmortem: it
* used to zero exactly CORE_BANK1's own footprint, because
* SYMADR=$2000 sat AT the blobs' own copy-source bytes and they
* were "dead the instant BLOCKCP consumed them" -- true within
* ONE run, and exactly why a WARM respawn (the lazy-free kernel
* handing a dying process's bank back to its own next spawn
* without recopying the image, src/kernel/lazyfree.s) would
* zero the blobs' OWN COPY IN THE IMAGE on run 1's way out, so
* run 2's BLOCKCP would copy zeros to $D000 and hang inside
* GTLEN reading THAT wreckage -- `ld` hit this exact bug first
* (docs/STICKY.md sec 29/31) and `as` could never even reach it,
* because its own entry head always moved first (see RESTHEAD's
* own header, below FINDEXIT) and so was never retained warm at
* all. Fixing THAT alone would have walked `as` straight into
* `ld`'s bug the moment it started being retained.
*
* THE FIX: SYMADR now lives ABOVE this file's own image end
* (see this file's header MEMORY LAYOUT table and the SYMADR
* equate's own comment, above) instead of inside it -- there is
* no window inside the image for the growing table to overrun,
* because there is no image byte up there to overrun. This
* ZEROFILL call now clears the ARENA (SYMADR..SRC_BASE-1), not
* the blobs -- and the blobs are consequently NEVER WRITTEN BY
* ANYTHING, ever again, the same invariant ld.s:1826-1829
* states for its own read-only blobs. CHKBLOB (below FINDEXIT)
* is the backstop if that ever stops being true.
ARENA_LEN   equ   SRC_BASE-SYMADR
            lda   #<SYMADR
            sta   PTR0
            lda   #>SYMADR
            sta   PTR0+1
            lda   #<ARENA_LEN
            sta   CPLEN
            lda   #>ARENA_LEN
            sta   CPLEN+1
            jsr   ZEROFILL

* SENDMSG stub ($E033, P6 amendment 2026-08-20, CORRECTED
* 2026-08-20): the core chain (ASS.BNK1.S/GETLINE.S/SYMPRINT.S/
* PRINTENT.S -- files this front end DOES embed, not MACED-
* only) calls `JSR SENDMSG` where SENDMSG=$E033 is one of the
* $E0xx resident-parameter-block ENTRIES that INTERPRETER.S's
* STARTUP normally installs at cold BRUN
* (learning:01M0CC62FZ351EBXCAAKX52KAJ's own "$E003 EXECWRM
* jmp stub, $E006 EXEC jmp stub..." list -- SENDMSG is a
* sibling of those, not one of P6's six monitor-ROM entries,
* and P6's enumeration missed it). `as.s` never runs STARTUP,
* so $E033 sits in the unbanked $E000-$E5EF gap neither
* CORE_BANK1 ($D000-$DFCC) nor CORE_AS ($E5F0+) covers --
* untouched, all-zero process-bank memory, i.e. a BRK ($00)
* waiting to fire.
*
* A bare-RTS stub (the original fix) is WRONG, not just
* expedient: every embedded-chain caller uses SENDMSG as an
