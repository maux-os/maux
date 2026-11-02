*---------------------------------------------------------------
* mld.s -- task #8's linker front end. Full spec:
* docs/LD-DESIGN.md
* (the plan and the phase-LD-A spike verdicts),
* docs/LD-RECON.txt
* (the byte-level evidence). Runs the SAME process core `as.s`
* already embeds (build/ascore-process-{bank1,as}.obj -- P1+P4+
* P5+P7+P10+P11+P12, gated by check-ascore-process) plus the
* SAME
* P6 ROM-stub blob (build/as-stubs.bin) -- LINKER.S calls into
* CORE_AS's BYTPRN/PRINTENT (LD-RECON section 5: "same-bank JSR,
* no cross-bank call needed") and the P6 stubs'
* COUT/CROUT/PRBYTE,
* so both blobs are embedded verbatim, unchanged, exactly as
* as.s
* built them. NO ldrom.s needed -- as-stubs.bin already carries
* everything LINKER.S calls into that isn't in
* CORE_BANK1/CORE_AS.
*
* CLI: ld [-o outfile] module.rel ... . Diagnostics "ld: ..." to
* stderr. Exit 0 on a clean link, 1 on a constraint error or a
* fatal link failure (bad module, etc), 2 on a usage error.
* Default output pathname (no -o given): LDOUT.
*
* THE $B200-PAGE CORRECTION (found building this file, NOT in
* docs/LD-DESIGN.md's LD-A4 table -- see src/merlin/patches.py's
* P12 group comment for the full writeup and the byte-level
* evidence). JCLOSE/JRLOAD/ENTRY are NOT INT+offset against
* INT=$E000 the way WRMVEC/SENDMSG/WARMDIS are (those three ARE
* literal $E0xx constants, confirmed correct) -- LINKER.S's own
* `JERROR = INT+$15` resolves against MACASS.S:49's `INT =
* $B200`,
* the only INT= definition in scope when LINKER.S is PUT. Direct
* byte search of build/ascore-process-bank1.obj confirms real
* JSR/JMP targets of $B20C (JCLOSE), $B215 (JERROR, but see
* below
* -- P12 redirects this one by source patch, not a stub), $B218
* (JRLOAD), $B240 (ENTRY, 8 call sites). This file installs its
* JCLOSE/JRLOAD/ENTRY stubs at THOSE addresses, not the $E0xx
* ones
* a naive reading of LD-A4 would suggest.
*
* THE MLI PARAMETER-BLOCK PAGE. LINKER.S's compiled
* open/newline/
* read/close calls carry hardcoded `LDX #<lowbyte>` operands
* that
* only make sense paired with a FIXED high byte -- $BE, matching
* vendor/merlin/MERLIN.GP.S's own `DUM $BE00 / PUT MERLIN.GP /
* DEND` (computed-address-only, no bytes emitted, per docs/AS-
* P10-ENUMERATION.txt's own finding on that file). Verified two
* ways: (1) a hand-written address-counting pass over
* MERLIN.GP.S
* (DFB/DA/STR/ASC/HEX/DS, including the `DS -2` rewind and the
* `DS $BE80-*` pad) cross-checked against that file's OWN
* internal
* ERR assertions (FILENAME-DOSFNAM-$40, the final `*-$BF00`);
* (2)
* grepping build/ascore-process-bank1.obj for the `LDX #imm /
* LDA
* #cmd / JSR $B240` triples and matching each low byte against
* the
* address-counting pass's own labels -- exact match at all 6
* real
* call sites (open/ODPARMS=$0E, newline/RNPARMS=$69, read names-
* file/RRPARMS=$6F, read module/RWPARMS=$06, close names-file/
* RCPARMS=$6D, close module/CLSPARMS=$1D). Two more $B240 call
* sites (setmark/MRKPARMS=$1F, write/DSKPARMS=$14) exist in the
* SAME object but belong to ASS.BNK1.S's own DODSK --
* DIRFLG-gated,
* DIRFLG never set (P7 neuters the only code that sets it, and
* `ld` never processes assembler source at all), same "provably
* unreachable" argument AS-DESIGN section 8 already made for
* `as`.
* This file therefore only implements open/newline/read/close.
*
* THE BUFFERED BRIDGE (docs/LD-DESIGN.md section 7a's ruling:
* one
* syscall per BLOCK, not per raw dictionary byte). Two DIFFERENT
* files flow through this bridge with two different strategies:
*
*   - The NAMES FILE (opened once via ENTRY's own "open" case)
* is
*     read through a real block buffer (LD_NMBUF, 256B) refilled
*     by ONE SC_READ per block; LNKLOOP's own mark-terminated
*     ("read until $00, or count-max, or EOF") record semantics
*     are implemented in software over that buffer, since maux's
*     SC_READ has no NEWLINE-mark concept of its own -- so
*     newline (the MLI call LINKER.S issues to arm it) is a
* no-op
*     here, and the mark-terminated behavior is hardcoded to
*     whichever call site (RRPARMS) is the only one that needs
* it.
*
*   - Each MODULE file is FRONT-LOADED whole by LD_JRLOAD (this
*     file's own $B218 stub, replacing RLOAD entirely -- LD-A3's
*     own finding that RLOAD bypasses ENTRY with its own SETBNK/
*     MAINZP/AUXZP sequence means bridging ENTRY alone could
* never
*     have covered it anyway). One module is never more than a
*     few KB for the sizes this slice targets, so reading the
*     WHOLE file (GET_FILE_INFO for the code-portion length in
*     aux_type, matching real RLOAD's own INFAUX use; the file's
*     own byte count from however many SC_READ calls it takes to
*     drain it) costs a handful of syscalls total and then
* serves
*     BOTH the code portion (copied straight to RWBUF) AND every
*     subsequent per-byte GENTRY dictionary read (LINKER.S:168-
*     174) from the SAME already-resident buffer -- zero further
*     syscalls until the module's own close. This is not the
*     "front-load ALL modules" Route 2 docs/LD-DESIGN.md section
* 5
*     rejected for window-budget reasons -- only ONE module's
* raw
*     bytes are ever resident at a time, matching how LINKER
*     itself processes modules strictly sequentially.
*
* THE EXIT PADS (src/merlin/patches.py's P12 group): LINKER.S's
* `JMP HIT`/`JMP JERROR` are source-patched into
* self-referencing
* landing pads (the exact ASEXIT shape, applied twice), found by
* the SAME self-jump scan technique as.s's FINDEXIT already
* uses,
* not hardcoded -- docs/LD-DESIGN.md section 1's own ruling that
* a
* front end must plant its own pads at BOTH vectors, since the
* landing address alone cannot distinguish success from a
* constraint error (that needs ORGFLG, LD-A2's finding, seeded
* nonzero before entry since LINK's own prologue never zeroes
* it).
*---------------------------------------------------------------
            lst   off
            xc
            org   LOAD_BASE
            dsk   ../../build/mld.bin
            typ   $00

            put   ../../inc/mm.procbank.equ
            put   ../../inc/mm.hw.equ
            put   ../../inc/sc.proc.equ
            put   ../../inc/sc.file.equ
            put   ../../inc/sc.fd.equ
            put   ../../inc/zp.equ
            put   ../../inc/stdio.equ
            put   ../../inc/startup.equ
            put   ../../inc/mli.equ

* -- core-fixed cells/addresses this front end reads/writes at
* the
* -- SAME locations LINKER.S/MACASS.S's own equates use. --
*-- MODMAX: hoisted from the bridge-state block (EQU
*-- burn-down 2026-08-29 -- it was used immediate before its
*-- definition, which real Merlin-8 refuses).
MODMAX      equ   32
LINK_ENTRY  equ   $D003
Z_LOADADR   equ   $16          ;2 bytes
STRINGS     equ   $860         ;names-file pathname,
                               ;NUL-terminated,
                                ;high-bit ASCII -- "cannot write
                                ;above $89F"
Z_SOURCE    equ   $0A
Z_ENDSRC    equ   $0E
Z_ERCOUNT   equ   $1D
Z_ORGFLG    equ   $E8          ;LD-A2: seed nonzero, LINK's own
                                ;prologue never zeroes it
Z_TRFL      equ   $5F          ;MACASS.S:109 "TRunc" -- ASS.
                                ;BNK1.S/LINKER.S's own "errors
                                ;only" flag (bit7). LINK's own
                                ;prologue never touches it
                                ;either (same class as ORGFLG)
                                ;-- found live (task report has
                                ;the trace): left clear,
                                ;LINKER.S:468's `BIT TRFL ;Only
                                ;errors wanted? / BMI :PA` takes
                                ;the VERBOSE "resolved" print
                                ;path (PRRES/CROUT/KEYCHK) after
                                ;every resolved external, which
                                ;drives a print chain this
                                ;bridge never exercised before
                                ;(nothing reached FIXCODE) and
                                ;which crashes (PC wanders into
                                ;the dictionary data region, a
                                ;stack/pointer corruption in
                                ;that unexercised path). Seeding
                                ;TRFL's bit7 takes the quiet
                                ;"errors only" branch instead --
                                ;correct for a headless batch
                                ;linker regardless (nobody reads
                                ;a "X resolved at $Y" banner
                                ;from `ld`), and sidesteps the
                                ;crash entirely.
Z_OBJPNT    equ   $E2          ;set by LINKED's tail -- captured
                                ;BEFORE any liba call, same
                                ;WRITEOBJ
                                ;discipline as.s already proved
Z_OBLEN     equ   $E4
CORE_D000   equ   $D000
CORE_E5F0   equ   $E5F0
STUB_FCA8   equ   $FCA8
SENDMSG_STUB equ  $E033
SENDMSG_IMPL equ  $FDF5        ;as-stubs.bin -- inline-string
                                ;printer, reused verbatim
WARMDIS_ADR equ   $E01B
AUXMOVE_ADR equ   $B260        ;P14 relocated this from $C311
                               ;(real
                                ;slot-ROM I/O space, unwritable
                                ;from a
                                ;process) -- see patches.py
* -- the $BE00 MLI parameter-block page (MERLIN.GP.S's DUM $BE00
* -- section) -- see this file's own header for how the offsets
* -- were derived and cross-checked. --
ODPARMS     equ   $BE0E
ODREF       equ   $BE13
DSKBUF_FLD  equ   $BE11        ;ODPARMS's own io_buffer field
                                ;(2-byte DA already baked into
                                ;the
                                ;object -- never read by us,
                                ;only
                                ;needs to exist so OPEN's own
                                ;pcount=3 shape stays intact)
RWPARMS     equ   $BE06
RWREF       equ   $BE07
RWBUF_FLD   equ   $BE08
RWCNT_FLD   equ   $BE0A
RWGOT_FLD   equ   $BE0C
RNPARMS     equ   $BE69
RNREF       equ   $BE6A
RCPARMS     equ   $BE6D
RCREF       equ   $BE6E
RRPARMS     equ   $BE6F
RRREF       equ   $BE70
RRBUF_FLD   equ   $BE71        ;fixed by LINKER.S's own compiled
                                ;bytes: IN+$80 = $280
RRCNT_FLD   equ   $BE73        ;fixed: $40 (64) -- count-max
RRGOT_FLD   equ   $BE75
CLSPARMS    equ   $BE1D
CLSREF      equ   $BE1E
DOSFNAM     equ   $BE80        ;[1 len][chars] -- reused for
                               ;BOTH
                                ;the names file's own path AND
                                ;each
                                ;module's path, high-bit as
                                ;LINKER.S
                                ;writes it; this file strips the
                                ;high bit IN PLACE before any
                                ;real
                                ;MLI/syscall use
BLEN_ADR    equ   $BE5E        ;2 bytes -- "Used by linker"
ADRS_ADR    equ   $14          ;2 bytes -- LINKER's own "true
                               ;(ORG)
                                ;address" cell, MACASS.S:78; not
                                ;used by this bridge directly
                                ;but
                                ;named here since it sits in the
                                ;same neighborhood as
                                ;LOADADR/ADRSV
IN_280      equ   $280         ;names-file record buffer --
                               ;fixed,
                                ;RRPARMS's own compiled buffer
                                ;ptr
IN_27F      equ   $27F         ;GENTRY's per-byte read target --
                                ;fixed, RWPARMS's own compiled
                                ;ptr
FROM_ZP     equ   $3C          ;AUXMOVE's real args (2 bytes
                               ;each)
ENDMOVE_ZP  equ   $3E
DEST_ZP     equ   $42
SCANBASE    equ   CORE_D000-2

*---------------------------------------------------------------
* START -- argv parse, embed the core, install the bridge, jump
* in. Never returns; MYEXIT lands here via the poked exit pads.
*---------------------------------------------------------------
            jmp   START

* $0800-$089F exclusion zone -- MACASS.S's DUMMY $800
* macro-state
* block sits AT LOAD_BASE. LINK's own prologue does not zero it
* (that is ASM_ENTRY-specific, never run here -- `ld` jumps
* straight to $D003), but LINKER.S DOES write PASNUM ($802,
* LINKER.S:55 "STA PASNUM ;Enable KEYCHK") and this file's own
* STRINGS write lands at $860, inside the SAME page -- so
* nothing
* of this file's own persistent code/data may live below $8A0
* either, same discipline as.s already established, for the same
* reason: avoid this program overwriting ITSELF when it pokes
* STRINGS at runtime.
            ds    $8A0-*

* Char-output helper, fixed at $08A0 -- as-stubs.bin's COUT JSRs
* here by that literal address (built once, shared with as.s,
* no visibility into this file's own labels).
* liba's buffered PUTC (src/liba/stdio.s, docs/PROCIO.md sec
* 4/5) stages every byte through LC bank 1 and, on the way out,
* reselects bank 2 (LC_KRN_RW/$C08B). It used to reselect it
* READ-ONLY ($C088), and THAT is what the hang below was: the
* same machine-wide write-enable latch that killed sh's segment
* install four weeks later (docs/LANGUAGE-CARD.md, 2026-09-20).
* Root cause fixed there -- nothing protects the LC any more --
* so the half of this bracket that was about WRITE-ENABLE is
* now redundant. The half that is about the BANK is not: PUTC
* still selects bank 1 for its own buffer, so the re-select
* below stays, and stays load-bearing.
*
* But CORE_D000's own embedded
* process core (LINKER.S in particular -- MACASS/ASSMAIN never
* exercise this, which is why check-as's own PUTC-through-the-
* core traffic never surfaced it) keeps writing into its own
* $D000-DFFF workspace throughout the run, and needs bank 2
* WRITE-ENABLED (LCBANK2_RAM/$C08B, this file's own BLOCKCP-to-
* CORE_D000 idiom above) to still be selected the instant it
* resumes after a COUT call -- LD_PUTCH is the ONLY place a
* liba call happens INSIDE the core's own execution window (as
* opposed to ld.s's own top-level code, which re-selects
* LCBANK2_RAM itself before every write it makes). Proven live
* (verilogapple, fast backend, 2026-08-20): routing LD_PUTCH
* through a raw unbuffered SC_WRITE with NO zero page touched
* but WITH just this same LC bank1-select/bank2-restore-RO
* bracket reproduced the identical hang check-ld was reporting
* (direct SPAWN(LD) pid 0, harness parked at step 2 -- sh's own
* WAIT on ld never returns because ld itself never reaches its
* own EXIT, spinning forever inside CORE_AS's copy/pad loop
* around $3EEE once its symbol-table bookkeeping starts reading
* back corrupted $D000+ bytes). Re-asserting LCBANK2_RAM here,
* AFTER PUTC returns and BEFORE control goes back to the core,
* restores exactly the state the core still expects -- narrow
* bracket, no syscall in between, same discipline stdio.s's own
* gate (d) already established.
LD_PUTCH    ldx   #FD_STDOUT
            jsr   PUTC
            lda   LCBANK2_RAM        ;re-select write-enable,
            lda   LCBANK2_RAM        ;double read (see BLOCKCP-
                                     ;to-CORE_D000 above)
            rts

* BLOBSIG -- the first three bytes of the embedded core as this
* run found them. CHKBLOB re-reads them on the way out; see its
* own header for what the comparison is for.
START       lda   CORE_BANK1
            sta   BLOBSIG
            lda   CORE_BANK1+1
            sta   BLOBSIG+1
            lda   CORE_BANK1+2
            sta   BLOBSIG+2
            stz   OFLAG
            stz   ZFLAG
            stz   MODCOUNT
*-- the link address defaults to LOAD_BASE -- where every maux
*-- binary loads -- spelled ONCE via the shared include (the
*-- SYMADR two-spellings lesson). -a overrides it; check-ld's
*-- own script passes `-a 2000` to keep matching the stock
*-- reference link.
            lda   #<LOAD_BASE
            sta   LNKADDR
            lda   #>LOAD_BASE
            sta   LNKADDR+1
            lda   #1
            sta   ARGI
:argloop    lda   ARGI
            cmp   ARGC
            bcc   :argmore
            jmp   :argsdone         ;out of short-branch range
                                    ;-- -a/-z grew the parser
:argmore    jsr   GETARG
            ldy   #0
            lda   (PTR0),y
            cmp   #$AD              ;'-' high-bit
            bne   :isPath
            iny
            lda   (PTR0),y
            cmp   #$EF              ;'o' high-bit
            beq   :isO
            cmp   #$E1              ;'a' high-bit
            beq   :isA
            cmp   #$FA              ;'z' high-bit
            bne   USAGE
            iny
            lda   (PTR0),y
            bne   USAGE             ;must be exactly "-z"
            lda   #1
            sta   ZFLAG
            jmp   :argnext
:isA        iny
            lda   (PTR0),y
            bne   USAGE             ;must be exactly "-a"
            lda   ARGI
            clc
            adc   #1
            cmp   ARGC
            bcs   USAGE             ;no operand follows -a
            sta   ARGI
            jsr   GETARG
            jsr   PARSEHEX          ;PTR0 string -> LNKADDR
            bcs   USAGE             ;empty or non-hex
            jmp   :argnext
:isO        iny
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
:isPath     lda   MODCOUNT
            cmp   #MODMAX
            bcs   USAGE             ;too many modules
            tax
            lda   ARGI
            sta   MODLIST,x
            inc   MODCOUNT
            jmp   :argnext
:argnext    inc   ARGI
            jmp   :argloop
:argsdone   lda   MODCOUNT
            bne   :havemods
USAGE       lda   #<USAGEMSG
            sta   PTR0
            lda   #>USAGEMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #2
            jsr   EXIT

*---------------------------------------------------------------
* Write the names file: [1 len][high-bit path bytes][$00] per
* module, one lone $00 to end (docs/LD-DESIGN.md section 2).
* Module argv strings are ALREADY high-bit ASCII (liba's own
* string convention) -- copied through verbatim, no translation.
*---------------------------------------------------------------
* NBPTR is a dedicated write cursor into NAMEBUF -- deliberately
* NOT PTR0 (the read pointer into each argv string below, via
* GETARG) or PTR1 (MKPATH's own dest arg right after this block)
* to avoid the two colliding mid-copy.
:havemods   lda   #<NAMEBUF
            sta   NBPTR
            lda   #>NAMEBUF
            sta   NBPTR+1
            ldx   #0
:modloop    cpx   MODCOUNT
            beq   :modsdone
            phx
            lda   MODLIST,x
            jsr   GETARG            ;-> PTR0 = arg string ptr
            ldy   #0
:slen       lda   (PTR0),y
            beq   :havelen
            iny
            bne   :slen
:havelen    tya                     ;Y = string length (0-255)
            sty   MODNMLEN
            ldy   #0
            sty   MODNMOFF
            lda   MODNMLEN
            jsr   NBEMIT            ;length byte
:scopy      ldy   MODNMOFF
            cpy   MODNMLEN
            beq   :scopydone
            lda   (PTR0),y
            jsr   NBEMIT
            inc   MODNMOFF
            bra   :scopy
:scopydone  lda   #0
            jsr   NBEMIT            ;terminator for this record
            plx
            inx
            jmp   :modloop
:modsdone   lda   #0
            jsr   NBEMIT            ;final lone $00

            lda   #<NAMEPATH
            sta   PTR0
            lda   #>NAMEPATH
            sta   PTR0+1
            lda   #<PATHBUF
            sta   PTR1
            lda   #>PATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<CRPARM
            ldx   #>CRPARM
            jsr   SC_CREAT          ;ok if it already exists
                                    ;from a
                                    ;prior run -- ignore the
                                    ;error,
                                    ;the OPEN right after is
                                    ;what
                                    ;matters
            lda   #<DOPARM
            ldx   #>DOPARM
            jsr   SC_OPEN
            bcc   :nfok
            lda   #<CANTNAMES
            ldx   #>CANTNAMES
            jsr   DIAG1
            lda   #1
            jsr   EXIT
:nfok       lda   DOPARM_REF
            sta   WPARM_REF
            lda   #<NAMEBUF
            sta   WPARM_BUF
            lda   #>NAMEBUF
            sta   WPARM_BUF+1
            sec
            lda   NBPTR
            sbc   #<NAMEBUF
            sta   WPARM_REQ
            lda   NBPTR+1
            sbc   #>NAMEBUF
            sta   WPARM_REQ+1
            lda   #<WPARM
            ldx   #>WPARM
            jsr   SC_WRITE
            lda   DOPARM_REF
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE

*---------------------------------------------------------------
* Embed the SAME process core and P6 stubs as.s already builds
* and gates (check-ascore-process, check-as) -- verbatim byte
* copies, each blob assembled AT its real target address.
*---------------------------------------------------------------
            lda   LCBANK2_RAM        ;write-enable, double read
            lda   LCBANK2_RAM        ;(house idiom -- see as.s's
                                     ;own note on the bank-name
                                     ;inversion)
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

* SYMADR ($2000) zero invariant -- LINKER's own DICPNT starts
* writing the dictionary at SYMADR the instant LINK runs
* (section 3's "free ride": LINKER reuses P1's SYMADR
* relocation), so that memory must start genuinely zero.
*
* THIS ZEROES LINKWIN, NOT THE BLOBS -- docs/STICKY.md sec 31.
* It used to zero the three blobs, which sat AT $2000 and were
* "dead the instant BLOCKCP consumed them". True within ONE run,
* and precisely why the SECOND `ld` of a boot died with
* "internal: exit pad not found": lazy free hands a respawn the
* bank the previous run left behind, so run 2's BLOCKCP copied
* 4,045 ZERO bytes to $D000 and FINDPADS scanned a core that was
* not there any more. The blobs now live ABOVE the window and
* nothing writes them; the window is scratch this program owns
* and clears at entry -- an invariant `ld` ESTABLISHES rather
* than one it inherits from a pristine image.
            lda   #<LINKWIN
            sta   PTR0
            lda   #>LINKWIN
            sta   PTR0+1
            lda   #<LINKWIN_LEN
            sta   CPLEN
            lda   #>LINKWIN_LEN
            sta   CPLEN+1
            jsr   ZEROFILL

* SENDMSG ($E033) -- reused verbatim from as.s's own fix: an
* inline-string call, bare RTS executes the string as code. See
* asrom.s's own SENDMSG_IMPL comment (this file embeds the SAME
* as-stubs.bin, so SENDMSG_IMPL is already at $FDF5).
            lda   #<SENDMSG_IMPL
            sta   SENDMSG_STUB+1
            lda   #>SENDMSG_IMPL
            sta   SENDMSG_STUB+2
            lda   #$4C               ;JMP
            sta   SENDMSG_STUB

* WARMDIS ($E01B) -- plain subroutine (LD-A4), called from
* ERRMEM/FILERR's cleanup path and FIXEXT's error-report tail.
* Its real body is a "warm display" screen redraw -- meaningless
* headless, same reasoning as as.s's own WARMDIS/JBELL no-ops.
            lda   #$60               ;RTS
            sta   WARMDIS_ADR

* AUXMOVE ($C311) -- 80-col-firmware entry, LINKED's own tail
* move (main -> SYMADR). A maux process has no separate aux bank
* of its OWN to hop to (P10's whole point) -- this is a plain
* same-bank copy using LINKER's own FROM/DEST/ENDMOVE cells.
            lda   #<LD_AUXMOVE
            sta   AUXMOVE_ADR+1
            lda   #>LD_AUXMOVE
            sta   AUXMOVE_ADR+2
            lda   #$4C
            sta   AUXMOVE_ADR

* JCLOSE ($B20C), JRLOAD ($B218), ENTRY ($B240) -- see this
* file's
* header for the address correction. All three are plain
* subroutines (LD-A4), installed the same JMP-stub way SENDMSG/
* AUXMOVE are above.
            lda   #<LD_JCLOSE
            sta   JCLOSE_ADR+1
            lda   #>LD_JCLOSE
            sta   JCLOSE_ADR+2
            lda   #$4C
            sta   JCLOSE_ADR

            lda   #<LD_JRLOAD
            sta   JRLOAD_ADR+1
            lda   #>LD_JRLOAD
            sta   JRLOAD_ADR+2
            lda   #$4C
            sta   JRLOAD_ADR

            lda   #<LD_ENTRY
            sta   ENTRY_ADR+1
            lda   #>LD_ENTRY
            sta   ENTRY_ADR+2
            lda   #$4C
            sta   ENTRY_ADR

*---------------------------------------------------------------
* Exit pads: scan CORE_BANK1 (just-copied, now at $D000) for the
* two self-jump landing pads src/merlin/patches.py's P12 group
* installs (LINKER.S:240/380 share one, LINKER.S:344 gets its
* own) -- found by address, never hardcoded, same discipline as
* as.s's own FINDEXIT. The lower address is always LD_EXIT1 (the
* HIT/success+constraint-error pad, since LINKER.S:240 precedes
* :344 in source and Merlin assembles sequentially).
*---------------------------------------------------------------
* A missing pad means the core that reached $D000 was not the
* core -- i.e. this bank's copy of the blobs was damaged before
* the run started. STAMPHEAD before giving up, so the kernel
* declines to retain the bank and the NEXT `ld` cold-loads a
* good image instead of inheriting the same wreckage forever.
            jsr   FINDPADS
            lda   PAD1
            ora   PAD1+1
            bne   :havepad1
            jsr   STAMPHEAD
            lda   #<NOPAD
            ldx   #>NOPAD
            jsr   DIAG1
            lda   #1
            jsr   EXIT
:havepad1   lda   PAD2
            ora   PAD2+1
            bne   :havepad2
            jsr   STAMPHEAD
            lda   #<NOPAD
            ldx   #>NOPAD
            jsr   DIAG1
            lda   #1
            jsr   EXIT
:havepad2   lda   PAD1
            sta   PTR0
            lda   PAD1+1
            sta   PTR0+1
            ldy   #0
            lda   #$4C
            sta   (PTR0),y
            iny
            lda   #<LD_HIT
            sta   (PTR0),y
            iny
            lda   #>LD_HIT
            sta   (PTR0),y

            lda   PAD2
            sta   PTR0
            lda   PAD2+1
            sta   PTR0+1
            ldy   #0
            lda   #$4C
            sta   (PTR0),y
            iny
            lda   #<LD_JERROR
            sta   (PTR0),y
            iny
            lda   #>LD_JERROR
            sta   (PTR0),y

*---------------------------------------------------------------
* Entry contract (docs/LD-DESIGN.md section 1, LD-A1/A2 proven):
* LOADADR, STRINGS (the names file's OWN pathname,
* NUL-terminated
* high-bit ASCII -- LINKER.S:63 reads it with a plain
* BEQ-on-zero
* loop, no high-bit stripping at this stage), SOURCE==ENDSRC
* (empty buffer), ORGFLG seeded nonzero (LD-A2's addition --
* LINK
* never zeroes it itself).
*---------------------------------------------------------------
            lda   LNKADDR
            sta   Z_LOADADR
            lda   LNKADDR+1
            sta   Z_LOADADR+1

            ldy   #0
:strloop    lda   NAMEPATH,y
            sta   STRINGS,y
            beq   :strdone
            iny
            bne   :strloop
:strdone

            lda   #<BUILDBASE
            sta   Z_SOURCE
            lda   #>BUILDBASE
            sta   Z_SOURCE+1
            lda   #<BUILDBASE
            sta   Z_ENDSRC
            lda   #>BUILDBASE
            sta   Z_ENDSRC+1

            lda   #$FF
            sta   Z_ORGFLG

            lda   #$80
            sta   Z_TRFL

* ODPARMS's own static fields (docs/AS-P10-ENUMERATION.txt's own
* finding, cited in this file's header: MERLIN.GP.S is PUT
* inside
* a DUM/DEND section, which computes ADDRESSES only, emitting NO
* real bytes anywhere -- so the $BE00 page is genuinely blank
* process memory at runtime, not pre-populated the way
* LINKER.S's
* own COMPILED references to it might suggest at a glance). This
* is the ONLY one of the six $BE00-page param blocks this bridge
* passes to the real syscall gate directly (ENT_OPEN) -- the
* other
* five are served from this file's OWN buffers/structures (see
* LD_ENTRY's header), so only ODPARMS needs pre-populating.
* io_buffer_ptr = $0000, same as-s's own OPARM_IOBF precedent
* ("kernel-owned", docs/USERLAND.md) -- as.s's own -o path
* already
* proves this is safe.
            lda   #3
            sta   ODPARMS
            lda   #<DOSFNAM
            sta   ODPARMS+1
            lda   #>DOSFNAM
            sta   ODPARMS+2
            stz   DSKBUF_FLD
            stz   DSKBUF_FLD+1

* Bridge state, reset fresh for this run.
            stz   NMFD
            stz   NMFILL
            stz   NMFILL+1
            stz   NMPOS
            stz   NMPOS+1
            stz   NMEOF
            stz   MODFD

            jmp   LINK_ENTRY

*---------------------------------------------------------------
* LD_HIT -- poked over LD_EXIT1 (P12's shared HIT pad: success
* via
* LINKED, or constraint-error via ERRMEM). ORGFLG distinguishes:
* LINKED clears it to 0, ERRMEM never touches it (LD-A2).
*---------------------------------------------------------------
*---------------------------------------------------------------
* PARSEHEX -- (PTR0) high-bit ASCII hex string (1-4 digits, no
* $ prefix: sh expands $ inside its own lines, so the operand a
* human can actually type is bare digits) -> LNKADDR. Carry set
* on empty string or a non-hex byte. Accepts both letter cases:
* the form a human types is the form the gate must gate.
*---------------------------------------------------------------
PARSEHEX    stz   LNKADDR
            stz   LNKADDR+1
            ldy   #0
            lda   (PTR0),y
            beq   :bad              ;empty operand
:digit      lda   (PTR0),y
            beq   :done
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #':'              ;'9'+1
            bcc   :num
            and   #$5F              ;fold lowercase
            cmp   #'A'
            bcc   :bad
            cmp   #'G'
            bcs   :bad
            sbc   #6                ;carry clear: A-G -> $3B-...
:num        and   #$0F
            asl   LNKADDR           ;value <<= 4
            rol   LNKADDR+1
            asl   LNKADDR
            rol   LNKADDR+1
            asl   LNKADDR
            rol   LNKADDR+1
            asl   LNKADDR
            rol   LNKADDR+1
            ora   LNKADDR
            sta   LNKADDR
            iny
            cpy   #5                ;more than 4 digits
            bcc   :digit
:bad        sec
            rts
:done       clc
            rts

LD_HIT      jsr   CHKBLOB
            lda   Z_ORGFLG
            beq   :linkok
            jmp   :constraint       ;out of short-branch range
                                    ;-- -z grew LD_HIT
:linkok
* Success -- capture OBLEN BEFORE any liba call (it aliases
* liba's own PTR2, the SAME collision as.s's WRITEOBJ already
* found and fixed the same way).
*
* THE OBJECT IS AT BUILDBASE, NOT AT Z_OBJPNT (sec 31). LINKED
* points OBJPNT at SYMADR ($2000) and asks AUXMOVE to copy the
* image down there; LD_AUXMOVE declines the copy and stashes the
* byte LINKED's own "buffer valid" $FF is about to land on, so
* the image is still exactly OBLEN bytes at SOURCE. Put that
* byte back and write from there -- same bytes, one memcpy and
* one collision with `ld`'s own text fewer.
            lda   SAVFIRST
            sta   BUILDBASE
            lda   #<BUILDBASE
            sta   SAVOBJPNT
            lda   #>BUILDBASE
            sta   SAVOBJPNT+1
            lda   Z_OBLEN
            sta   SAVOBLEN
            lda   Z_OBLEN+1
            sta   SAVOBLEN+1
*-- OBLEN past the build window means zero bytes were dropped at
*-- copy time (the clamp above refused every other case) --
*-- clamp so the write and the -z scan stay inside the window
            lda   SAVOBLEN+1
            cmp   #>BLDWINMAX
            bcc   :oblok
            bne   :oblclamp
            lda   SAVOBLEN
            beq   :oblok            ;== BLDWINMAX exactly
:oblclamp   lda   #<BLDWINMAX
            sta   SAVOBLEN
            lda   #>BLDWINMAX
            sta   SAVOBLEN+1
:oblok
*-- -z: drop the trailing all-zero span -- the bss modules a
*-- REL-route link places LAST (S9-PLAN sec 6 L3). Backward scan
*-- from the image end; the byte-identity gate catches any
*-- over-trim (a real binary ending in zeros would come out
*-- short and fail its compare loudly).
            lda   ZFLAG
            beq   :nozip
            lda   SAVOBJPNT
            clc
            adc   SAVOBLEN
            sta   PTR0
            lda   SAVOBJPNT+1
            adc   SAVOBLEN+1
            sta   PTR0+1            ;PTR0 = one past image end
:ziploop    lda   SAVOBLEN
            ora   SAVOBLEN+1
            beq   :nozip            ;never truncate to empty
            lda   PTR0
            bne   :zdec1
            dec   PTR0+1
:zdec1      dec   PTR0
            ldy   #0
            lda   (PTR0),y
            bne   :zipdone          ;nonzero byte: stop
            lda   SAVOBLEN
            bne   :zdec2
            dec   SAVOBLEN+1
:zdec2      dec   SAVOBLEN
            bra   :ziploop
:zipdone
:nozip
*-- the output carries its link address in aux_type -- the
*-- honour-aux convention (S9-PLAN sec 6 L3b), producer side.
            lda   LNKADDR
            sta   OCRPARM_AUX
            lda   LNKADDR+1
            sta   OCRPARM_AUX+1
            lda   OFLAG
            bne   :haveoflag
            lda   #<DEFOUT
            sta   OBJPTR
            lda   #>DEFOUT
            sta   OBJPTR+1
:haveoflag  jsr   WRITEOBJ
            bcc   :wrok
            lda   #<CANTWROBJ
            ldx   #>CANTWROBJ
            jsr   DIAG1
            lda   #1
            jsr   EXIT
:wrok       lda   #0
            jsr   EXIT
:constraint lda   #<CONSTRMSG
            ldx   #>CONSTRMSG
            jsr   DIAG1
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* LD_JERROR -- poked over LD_EXIT2 (FILERR's fatal `JMP
* JERROR`).
* A holds the ProDOS-style error code FILERR pulled just before
* the jump (LINKER.S:340/343-344 -- PHA before JCLOSE/WARMDIS,
* PLA right before the jump, so A survives the redirect intact).
*---------------------------------------------------------------
LD_JERROR   sta   ERRCODE
            jsr   CHKBLOB
            lda   #<FATALMSG
            sta   PTR0
            lda   #>FATALMSG
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   ERRCODE
            jsr   PRHEXA
            lda   #$29               ;')' high-bit
            ora   #$80
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            lda   #1
            jsr   EXIT

*---------------------------------------------------------------
* LD_JCLOSE ($B20C) -- "close all entries" (LD-A4). Closes
* whichever of the names-file / module fds this bridge still has
* open; failures ignored (best-effort cleanup, same as the real
* routine's own unconditional-success shape from its callers'
* point of view -- LD-A4 confirms no caller branches on it).
*---------------------------------------------------------------
LD_JCLOSE   lda   NMFD
            beq   :nonm
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   NMFD
:nonm       lda   MODFD
            beq   :nomod
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   MODFD
:nomod      rts

*---------------------------------------------------------------
* LD_ENTRY ($B240) -- the buffered ENTRY bridge. IN: A=MLI
* command,
* X=low byte of the $BE00-page param block. See this file's own
* header for the dispatch table and the buffering strategy.
* OUT: A=0/carry clear on success (matching real MLI convention,
* which GENTRY/LNKLOOP both test via a plain `BNE`/`TAY` on A).
*---------------------------------------------------------------
* Direct BEQ to these targets can exceed the 65C02's +/-127-byte
* branch range once the bridge grows -- bounce off a same-page
* BNE-skip-a-JMP trampoline instead (each JMP is in range of its
* own BEQ by construction).
* Literal MLI command bytes here, NOT the SYS_* equates (even
* though they're numerically identical, maux's own syscalls
* being literally the MLI call numbers by design) -- A holds
* LINKER.S's own real MLI command byte, not a syscall dispatch
* this file is making, and check-userland's own choke-point
* audit (src/liba is the only place SYS_*/raw call numbers may
* appear)
* does not distinguish the two uses.
*
* PHY/PLY around the WHOLE dispatch (found live, task report
* has the trace -- SAME shape as NMGETC's own PHY/PLY and
* SENDMSG_IMPL's Y-preserving fix, a third instance of the
* identical bug class): real ProDOS MLI calls are documented
* to preserve X and Y, and LINKER.S's own FIXEXT relies on
* this -- `LNKLOOP`'s `JMLI close;RC` (closing the names
* file) is immediately followed by `JMP FIXEXT`, whose own
* prologue does `TYA / STA (DICPNT),Y ;Mark end of dict`
* using the SAME Y the close call was supposed to leave
* untouched (Y=0, freshly set by `LDY IN+$80` reading the
* EOF record's own zero length byte just before the close).
* But every `SC_*` routine this bridge calls (`src/liba/
* syscalls.s`) loads Y with the syscall NUMBER before
* calling the kernel's own gate and never restores the
* caller's own Y -- so the close call left Y as garbage
* (confirmed live: Y=$CC, not $00, at LINKER's own NXADR
* right after), FIXEXT wrote that
* garbage byte as BOTH the dictionary "end" marker's value
* AND its own index (`STA (DICPNT),Y`), and the resolution
* walk's very first `NXADR` (`STADR SYMADR-1;PL` / two
* `GETPL` reads) landed on a dictionary byte that was never
* the terminator LINKER.S expects -- `BEQ LINKED` fired on
* NXADR's OWN FIRST pass, before GETEX/FINDENT/FIXCODE ever
* ran, exactly matching the "FIXCODE never called, ERCOUNT=0,
* raw placeholder bytes reach the output" symptom. Fixed the
* general way, not by patching FIXEXT's one call site:
* LD_ENTRY is the SHARED gateway for every open/newline/read/
* close LINKER.S makes (the real ENTRY's own job), so it --
* not each individual call site -- is where the real MLI's
* Y-preservation contract belongs.
LD_ENTRY    phy
            cmp   #$C8               ;MLI open
            bne   :notopen
            jsr   ENT_OPEN
            bra   :ldret
:notopen    cmp   #$C9               ;MLI newline -- maux has no
                                     ;syscall for this at all
            bne   :notnl
            jsr   ENT_NEWLINE
            bra   :ldret
:notnl      cmp   #$CA               ;MLI read
            bne   :notread
            jsr   ENT_READ
            bra   :ldret
:notread    cmp   #$CC               ;MLI close
            bne   :notclose
            jsr   ENT_CLOSE
            bra   :ldret
:notclose
* Unreached in practice (setmark/write are DIRFLG-gated dead
* code,
* see this file's header) -- fail loudly rather than silently.
            lda   #$46
            clc
:ldret      ply
            rts

ENT_OPEN    jsr   STRIPFNAM
            lda   #<ODPARMS
            ldx   #>ODPARMS
            jsr   SC_OPEN
            bcs   :fail
            lda   ODREF
            sta   NMFD
            sta   RNREF
            sta   RCREF
            sta   RRREF
            stz   NMFILL
            stz   NMFILL+1
            stz   NMPOS
            stz   NMPOS+1
            stz   NMEOF
            lda   #0
            clc
            rts
:fail       lda   #$4A
            sec
            rts

ENT_NEWLINE lda   #0
            clc
            rts

ENT_READ    cpx   #<RRPARMS
            beq   ENT_RDNAMES
            cpx   #<RWPARMS
            beq   ENT_RDMOD
            lda   #$46
            sec
            rts

* Mark-terminated ($00) buffered read of the names file, served
* into $280 (RRPARMS's own fixed buffer), up to 64 bytes
* (RRPARMS's own fixed count-max), refilling LD_NMBUF from the
* real file ONE SC_READ per block (docs/LD-DESIGN.md section
* 7a).
ENT_RDNAMES ldy   #0
:loop       cpy   #$40
            beq   :done
            jsr   NMGETC
            bcs   :eofcheck
            sta   IN_280,y
            iny
            cmp   #0
            beq   :done
            bra   :loop
:eofcheck   cpy   #0
            bne   :done             ;delivered at least the mark
                                    ;byte's worth before EOF hit
                                    ;--
                                    ;treat as a short,
                                    ;successful
                                    ;record
            lda   #$4C              ;true EOF, nothing delivered
            sec
            rts
:done       sty   RRGOT_FLD
            stz   RRGOT_FLD+1
            lda   #0
            clc
            rts

* Raw single-byte read from the CURRENT MODULE's own pre-loaded
* buffer (populated whole by LD_JRLOAD) -- no syscall at all.
ENT_RDMOD   lda   MODPOS
            cmp   MODLEN
            lda   MODPOS+1
            sbc   MODLEN+1
            bcc   :havebyte
            lda   #$4C               ;past EOF -- malformed
                                     ;module
            sec
            rts
*-- MODPOS is a FILE OFFSET (LINKER.S's own bookkeeping, and
*-- BLEN is the module's whole length), but MODBUF now holds
*-- ONLY the dictionary -- the code streamed past it. So the
*-- dictionary's first byte, at file offset MODCODELEN, lives at
*-- MODBUF[0], and the index is MODPOS - MODCODELEN.
:havebyte   sec
            lda   MODPOS
            sbc   MODCODELEN
            sta   PTR0
            lda   MODPOS+1
            sbc   MODCODELEN+1
            sta   PTR0+1
            clc
            lda   PTR0
            adc   #<MODBUF
            sta   PTR0
            lda   PTR0+1
            adc   #>MODBUF
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            sta   IN_27F
            inc   MODPOS
            bne   :nc
            inc   MODPOS+1
:nc         lda   #0
            clc
            rts

ENT_CLOSE   cpx   #<RCPARMS
            beq   :closenm
            cpx   #<CLSPARMS
            beq   :closemod
            lda   #0
            clc
            rts
:closenm    lda   NMFD
            beq   :ok
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   NMFD
            bra   :ok
:closemod   lda   MODFD
            beq   :ok
            sta   CPARM_REF
            lda   #<CPARM
            ldx   #>CPARM
            jsr   SC_CLOSE
            stz   MODFD
:ok         lda   #0
            clc
            rts

*---------------------------------------------------------------
* NMGETC -- deliver the next raw byte of the names file, filling
* LD_NMBUF (one real SC_READ) whenever it runs dry. OUT: carry
* clear + A=byte, or carry set at true EOF.
*
* PHY/PLY around the whole body: this routine's own `LDY #0`
* (below) and SC_READ's own body (liba, not this file's own
* code, cannot be assumed to preserve Y) would otherwise clobber
* the CALLER's own Y -- found live
* (docs/LD-DESIGN.md's own task report has the full trace): ENT_
* RDNAMES uses Y as its own byte-counter across repeated NMGETC
* calls, and without this save/restore every call reset it to 0,
* so the counter never advanced past 1 and every byte overwrote
* IN_280's first slot instead of filling the record.
*---------------------------------------------------------------
NMGETC      phy
            lda   NMPOS
            cmp   NMFILL
            lda   NMPOS+1
            sbc   NMFILL+1
            bcc   :havedata
            lda   NMEOF
            bne   :trueeof
            lda   NMFD
            sta   NMRPARM_REF
            lda   #<NMBUF
            sta   NMRPARM_BUF
            lda   #>NMBUF
            sta   NMRPARM_BUF+1
            lda   #<NMBUF_SZ
            sta   NMRPARM_REQ
            lda   #>NMBUF_SZ
            sta   NMRPARM_REQ+1
            lda   #<NMRPARM
            ldx   #>NMRPARM
            jsr   SC_READ
            lda   NMRPARM_TRANS
            sta   NMFILL
            lda   NMRPARM_TRANS+1
            sta   NMFILL+1
            ora   NMFILL
            bne   :gotmore
            lda   #1
            sta   NMEOF
:gotmore    stz   NMPOS
            stz   NMPOS+1
            lda   NMFILL
            ora   NMFILL+1
            beq   :trueeof
:havedata   lda   NMPOS
            sta   PTR0
            lda   NMPOS+1
            sta   PTR0+1
            clc
            lda   PTR0
            adc   #<NMBUF
            sta   PTR0
            lda   PTR0+1
            adc   #>NMBUF
            sta   PTR0+1
            ldy   #0
            lda   (PTR0),y
            pha
            inc   NMPOS
            bne   :nc
            inc   NMPOS+1
:nc         pla                      ;the byte to return (pushed
                                     ;before Y below -- pop in
                                     ;the
                                     ;reverse order)
            ply                      ;restore CALLER's Y
            clc
            rts
:trueeof    ply                      ;restore CALLER's Y
            sec
            rts

*---------------------------------------------------------------
* STRIPFNAM -- IN PLACE, strip the high bit off every char byte
* of DOSFNAM ([1 len][chars]) so it is a real MLI-shaped
* pathname
* (7-bit, length-prefixed, TRM ch.2/4). Reused for BOTH the
* names
* file's own open (via ODPARMS) and each module's open
* (LD_JRLOAD
* below).
*---------------------------------------------------------------
STRIPFNAM   ldy   DOSFNAM
            beq   :done
:loop       lda   DOSFNAM,y
            and   #$7F
            sta   DOSFNAM,y
            dey
            bne   :loop
:done       rts

            put   mldload.s

*---------------------------------------------------------------
* LD_AUXMOVE ($C311, relocated to $B260 by P14) -- LINKED's own
* "move the linked image to SYMADR" hook. A process's kernel-set
* baseline already puts this data where it belongs (P10's whole
* point) -- no switch flips.
*
* HISTORY WORTH KEEPING, because it is why this routine must not
* touch liba's PTR pair even now. When this was a copy loop it
* deliberately used FROM_ZP/DEST_ZP as the (zp),y pointers and
* NOT liba's PTR0/PTR1: PTR1 ($E2) IS OBJPNT byte-for-byte, and
* LINKED sets OBJPNT=$2000 immediately before calling AUXMOVE,
* so a PTR1 destination pointer incremented OBJPNT once per byte
* copied -- corrupting the very cell LD_HIT read back afterward,
* and sending every byte after the first into unrelated process
* memory (LD-RECON section 4; same collision as.s's own WRITEOBJ
* hit). Anything added here inherits that constraint.
*---------------------------------------------------------------
* THE MOVE IS ELIDED, and that is the point (docs/STICKY.md sec
* 31). LINKED's only use of AUXMOVE is to copy the finished
* image from SOURCE down to SYMADR ($2000) -- a plain memcpy of
* OBLEN bytes, and $2000 is inside LINKWIN, where an object
* bigger than the window would run into `ld`'s own blobs. There
* is no reason to move it at all: LD_HIT writes the object out
* of BUILDBASE (== SOURCE == FROM) instead, which is the same
* bytes at their original address, so the file `ld` emits is
* byte-identical to what the copy would have produced --
* scripts/check_ld.py compares it against stock Merlin `LINK`
* and would say so otherwise.
*
* ONE BYTE HAS TO BE RESCUED. Immediately after `JSR AUXMOVE`,
* LINKED does `LDA #$FF / LDY #0 / STA (ENDSRC),Y` -- its
* "buffer valid" flag -- and START set ENDSRC to BUILDBASE (the
* documented SOURCE==ENDSRC entry contract), so that $FF lands
* on the object's FIRST byte. Stash it here, where FROM still
* points at SOURCE, and LD_HIT puts it back before WRITEOBJ.
*
* SAFE BECAUSE THERE IS EXACTLY ONE CALLER. Verified by byte
* search of the embedded objects for `JSR $B260` (P14's
* relocated AUXMOVE): one hit, at $D280, LINKED's own. The
* assembler halves of the same core (CORE_AS, the P6 stubs)
* contain none -- and `ld` never runs the assembler anyway, the
* same "provably unreachable" argument this file's header
* already makes for DODSK's setmark/write call sites.
LD_AUXMOVE  ldy   #0
            lda   (FROM_ZP),y
            sta   SAVFIRST
            rts

*---------------------------------------------------------------
* WRITEOBJ -- create/open OBJPTR's path, write SAVOBLEN bytes
* starting at SAVOBJPNT (already captured), close. Same shape as
* as.s's own WRITEOBJ, same zero-page-collision discipline.
*---------------------------------------------------------------
WRITEOBJ    lda   OBJPTR
            sta   PTR0
            lda   OBJPTR+1
            sta   PTR0+1
            lda   #<OPATHBUF
            sta   PTR1
            lda   #>OPATHBUF
            sta   PTR1+1
            jsr   MKPATH
            lda   #<OCRPARM
            ldx   #>OCRPARM
            jsr   SC_CREAT
            bcs   :fail
            lda   #<ODPARM2
            ldx   #>ODPARM2
            jsr   SC_OPEN
            bcs   :fail
            lda   ODPARM2_REF
            sta   OWPARM_REF
            lda   SAVOBJPNT
            sta   OWPARM_BUF
            lda   SAVOBJPNT+1
            sta   OWPARM_BUF+1
            lda   SAVOBLEN
            sta   OWPARM_REQ
            lda   SAVOBLEN+1
            sta   OWPARM_REQ+1
            lda   #<OWPARM
            ldx   #>OWPARM
            jsr   SC_WRITE
            bcs   :fail
            lda   ODPARM2_REF
            sta   OCPARM_REF
            lda   #<OCPARM
            ldx   #>OCPARM
            jsr   SC_CLOSE
            clc
            rts
:fail       sec
            rts

*---------------------------------------------------------------
* BLOCKCP/ZEROFILL -- reused verbatim from as.s. IN PTR0=src
* (BLOCKCP
* only), PTR1=dst, CPLEN=length (2 bytes, must be > 0).
*---------------------------------------------------------------
BLOCKCP     ldy   #0
:loop       lda   CPLEN
            ora   CPLEN+1
            beq   :done
            lda   (PTR0),y
            sta   (PTR1),y
            inc   PTR0
            bne   :nc1
            inc   PTR0+1
:nc1        inc   PTR1
            bne   :nc2
            inc   PTR1+1
:nc2        lda   CPLEN
            bne   :dec1
            dec   CPLEN+1
:dec1       dec   CPLEN
            bra   :loop
:done       rts

ZEROFILL    ldy   #0
:loop       lda   CPLEN
            ora   CPLEN+1
            beq   :done
            lda   #0
            sta   (PTR0),y
            inc   PTR0
            bne   :nc1
            inc   PTR0+1
:nc1        lda   CPLEN
            bne   :dec1
            dec   CPLEN+1
:dec1       dec   CPLEN
            bra   :loop
:done       rts

*---------------------------------------------------------------
* CHKBLOB / STAMPHEAD -- the backstop under LINKWIN's size
* (docs/STICKY.md sec 31).
*
* Nothing in the Merlin core bounds its dictionary below $BE00,
* so a link with enough externals can grow out of LINKWIN and
* into the embedded blobs. That does not hurt the run doing it
* -- the blobs were copied to $D000/$E5F0/$FCA8 at entry and are
* dead -- but under lazy free the bank is RETAINED, and the next
* `ld` of the boot would copy the wreckage to $D000 and die in
* FINDPADS with "internal: exit pad not found". That is exactly
* the failure sec 29 recorded, and it is not acceptable to leave
* a smaller version of it behind.
*
* The dictionary grows UPWARD from SYMADR, so it reaches
* CORE_BANK1's first byte before any other blob byte: three
* bytes are a sufficient detector, the same argument (and the
* same shape) as the kernel's own eight-byte entry-head check.
*
* STAMPHEAD writes a byte the kernel WILL notice. LZ_RETAIN
* re-reads LZ_HEAD_LEN bytes at LOAD_BASE before it promises a
* dying bank still holds the program, and refuses to retain it
* if they moved (sec 27). Clearing the first byte of this
* file's own `jmp START` is the cheapest way to fail that check
* on purpose -- it is `ld`'s own instruction, it has already
* executed for the last time this process, and the next spawn
* cold-loads a fresh image and works. No new syscall, no ABI.
*---------------------------------------------------------------
CHKBLOB     lda   CORE_BANK1
            cmp   BLOBSIG
            bne   STAMPHEAD
            lda   CORE_BANK1+1
            cmp   BLOBSIG+1
            bne   STAMPHEAD
            lda   CORE_BANK1+2
            cmp   BLOBSIG+2
            bne   STAMPHEAD
            rts

STAMPHEAD   lda   #0
            sta   LOAD_BASE
            rts

*---------------------------------------------------------------
* FINDPADS -- scan CORE_D000..CORE_D000+CORE_B1_LEN-3 for 3-byte
* self-jumps (P12's LD_EXIT1/LD_EXIT2 pads). OUT: PAD1 = the
* FIRST one found (lower address -- LINKER.S:240's site), PAD2 =
* the second (LINKER.S:344's site), or 0/0 if not found.
*---------------------------------------------------------------
FINDPADS    lda   #<CORE_D000
            sta   PTR0
            lda   #>CORE_D000
            sta   PTR0+1
            clc
            lda   #<CORE_B1_LEN
            adc   #<SCANBASE
            sta   SCANEND
            lda   #>CORE_B1_LEN
            adc   #>SCANBASE
            sta   SCANEND+1
            stz   PAD1
            stz   PAD1+1
            stz   PAD2
            stz   PAD2+1
:loop       lda   PTR0+1
            cmp   SCANEND+1
            bne   :cont
            lda   PTR0
            cmp   SCANEND
            beq   :done
:cont       ldy   #0
            lda   (PTR0),y
            cmp   #$4C
            bne   :next
            iny
            lda   (PTR0),y
            sta   FE_LO
            iny
            lda   (PTR0),y
            sta   FE_HI
            lda   FE_LO
            cmp   PTR0
            bne   :next
            lda   FE_HI
            cmp   PTR0+1
            bne   :next
            lda   PAD1
            ora   PAD1+1
            bne   :setpad2
            lda   PTR0
            sta   PAD1
            lda   PTR0+1
            sta   PAD1+1
            bra   :skip3
:setpad2    lda   PTR0
            sta   PAD2
            lda   PTR0+1
            sta   PAD2+1
:skip3      clc
            lda   PTR0
            adc   #3
            sta   PTR0
            bcc   :loop
            inc   PTR0+1
            bra   :loop
:next       inc   PTR0
            bne   :loop
            inc   PTR0+1
            bra   :loop
:done       rts

*---------------------------------------------------------------
* NBEMIT -- append A at NBPTR (a direct write cursor into
* NAMEBUF) and bump it. NBPTR itself is ordinary (non-zero-page)
* memory -- (zp),y addressing needs a zero-page operand, so this
* copies it through PTR1 each call (free during :havemods's own
* copy loop: PTR0 holds the argv-string read pointer, MKPATH
* -- the only other PTR1 use nearby -- runs strictly AFTER this
* whole loop finishes). No overflow guard beyond NAMEBUF's own
* generous size (see MODMAX/NAMEBUF sizing below) -- check-ld's
* own modules are tiny; a real-world `ld` with hundreds of
* modules would need a real cap here.
*---------------------------------------------------------------
NBEMIT      pha
            lda   NBPTR
            sta   PTR1
            lda   NBPTR+1
            sta   PTR1+1
            pla
            ldy   #0
            sta   (PTR1),y
            inc   NBPTR
            bne   :nc
            inc   NBPTR+1
:nc         rts

*---------------------------------------------------------------
* PRHEXA -- print A as 2 high-bit-ASCII hex digits to stderr.
*---------------------------------------------------------------
PRHEXA      pha
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            jsr   :nib
            pla
:nib        and   #$0F
            cmp   #$0A
            bcc   :dec
            clc
            adc   #7
:dec        adc   #$B0              ;'0' high-bit + digit
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* DIAG1 -- "ld: " + message + CR to stderr.
*---------------------------------------------------------------
DIAG1       sta   DG_MSGLO
            stx   DG_MSGHI
            lda   #<ERRPFX
            sta   PTR0
            lda   #>ERRPFX
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   DG_MSGLO
            sta   PTR0
            lda   DG_MSGHI
            sta   PTR0+1
            ldx   #FD_STDERR
            jsr   PUTS
            lda   #$8D
            ldx   #FD_STDERR
            jsr   PUTC
            rts

*---------------------------------------------------------------
* Data.
*---------------------------------------------------------------
USAGEMSG    asc   "usage: ld [-a adr] [-z] [-o out] mod ..."
            dfb   $8D,0
ERRPFX      asc   "ld: "
            dfb   0
CANTNAMES   asc   "cannot create names file"
            dfb   0
CANTWROBJ   asc   "write failed"
            dfb   0
CONSTRMSG   asc   "constraint error"
            dfb   0
FATALMSG    asc   "ld: link failed (error $"
            dfb   0
NOPAD       asc   "internal: exit pad not found"
            dfb   0
CANTMOD     asc   "cannot open module"
            dfb   0
TOOBIGMOD   asc   "module too large"
            dfb   0
TOOBIGIMG   asc   "image too large"
            dfb   0
NAMEPATH    asc   "LDNAMES"
            dfb   0

OFLAG       ds    1
ZFLAG       ds    1          ;-z: truncate trailing zero span
LNKADDR     ds    2          ;link address (-a, else LOAD_BASE)
ARGI        ds    1
MODCOUNT    ds    1
*-- MODMAX: hoisted to the top equ block (EQU burn-down).
MODLIST     ds    MODMAX
OBJPTR      ds    2
CPLEN       ds    2
SCANEND     ds    2
PAD1        ds    2
PAD2        ds    2
FE_LO       ds    1
FE_HI       ds    1
DG_MSGLO    ds    1
DG_MSGHI    ds    1
ERRCODE     ds    1
SAVOBJPNT   ds    2
SAVOBLEN    ds    2
SAVFIRST    ds    1
BLOBSIG     ds    3
NBPTR       ds    2
MODNMLEN    ds    1
MODNMOFF    ds    1

* -- BUILDBASE: SOURCE==ENDSRC, LINKER's accumulation area --
* -- every module's code lands here as it is read, and the
* -- finished image is OBLEN bytes starting here. It is this
* -- file's choice, not the core's: LINK reads it out of the
* -- SOURCE zero-page pair START seeds. Raised $6000 -> $6C00 by
* -- sec 31 so MODBUF could leave the image for the `dum` arena,
* -- which sits between LIBA_BSSEND and this address; the
* -- arena's own `err */BUILDBASE` asserts they do not overlap.
* -- Headroom for the linked image is BUILDBASE..$BE00 (the
* -- dictionary's own MEMCHK ceiling), 20,736 B here against
* -- 9,216 before, because the image no longer has to fit under
* -- MODBUF as well.
* --
* -- $6C00 -> $6D00, 2026-08-24: liba's write-error path (see
* -- src/liba/stdio.s's THE ERROR PATH) added text to every
* -- program that links stdio, LIBA_BSSEND moved up with it, and
* -- MODBUF's $1000 arena ran into $6C00 -- the `err` below
* -- is what said so, at assembly time, before anything
* -- ran. Raising this constant is the sanctioned knob for it
* -- (the note above is sec 31 doing the same thing), and it
* -- costs 256 B of linked-image headroom out of ~21 KB.
* -- Measured: ld.bin 20,370 B + liba's 1,165 B arena puts
* -- LIBA_BSSEND at $5C1F, so MODBUF ends at $6C1F -- 31 B OVER
* -- the old ceiling and 225 B under the new one.
* --
* -- $6D00 -> $6E00, 2026-08-28: same knob, same shape --
* -- docs/PERF-PLAN.md steps 2+4 added text to every liba
* -- consumer (regex.s's star-before-disjoint-atom fast path;
* -- stdio.s's SIO_MODEOF probe + PUTS's buffered path) and 9
* -- bss bytes (SIO_MODE + SIO_FDPARM), and MODBUF's arena end
* -- crossed $6D00. The `err` below said so at assembly time,
* -- which is exactly its job. Costs another 256 B of linked-
* -- image headroom out of ~21 KB.
* --
* -- $6E00 -> $7100, 2026-08-29: the stage-owner buffering grew
* -- liba's arena by 537 (SIO_STAGE 512->1024 + the geometry
* -- tables). Same knob, same tripwire, 768 B more headroom
* -- spent.
*-- BUILDBASE dropped $8200 -> $7300 when LD_JRLOAD started
*-- STREAMING module code instead of staging whole modules: the
*-- arena now ends at $6044 instead of $8138 -- module code is
*-- STREAMED rather than staged, and MODBUF itself has moved out
*-- from under BUILDBASE entirely, up into the dead space above
*-- BLDTOP. Build window BLDTOP-BUILDBASE goes 12,288 -> 20,736
*-- bytes, which clears EVERY kernel .SYSTEM image: the largest
*-- is MAUXEXPR at 20,059 B, leaving 677 B of margin. The `err
*-- */BUILDBASE` at the arena's end is what keeps the two from
*-- ever overlapping.
BUILDBASE   equ   $6100
*-- BLDTOP, the build ceiling: the bridge stubs live at
*-- $B20C/$B218/$B240/$B260 (JCLOSE/JRLOAD/ENTRY/AUXMOVE).
*-- An image byte placed there is a stub overwrite -- found
*-- live when diff's bss chunks zeroed $B240 and the core's
*-- next JSR hit BRK.
BLDTOP      equ   $B200
BLDWINMAX   equ   BLDTOP-BUILDBASE

* Bridge state (front-end owned).
NMFD        ds    1
NMFILL      ds    2
NMPOS       ds    2
NMEOF       ds    1
MODFD       ds    1
MODLEN      ds    2
MODCODELEN  ds    2
MODPOS      ds    2

NMBUF_SZ    equ   256
NMBUF       ds    NMBUF_SZ

* Names-file staging buffer: MODMAX(32) records, each up to
* 1(len)+64(MLI_PTH_MAXLN)+1(terminator)=66 bytes, plus the
* final
* lone $00 -- 32*66+1=2113 (merlin32 cannot evaluate a
* parenthesized
* `ds` expression, so the arithmetic is spelled out here
* instead).
NAMEBUF     ds    2113

PATHBUF     ds    65
OPATHBUF    ds    65

CRPARM        dfb   PCOUNT_CREATE
CRPARM_PATH   da    PATHBUF
CRPARM_ACCESS dfb   ACCESS_UNLKD
CRPARM_TYPE   dfb   FTYPE_TXT
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

CPARM       dfb   PCOUNT_CLOSE
CPARM_REF   dfb   0

OCRPARM        dfb   PCOUNT_CREATE
OCRPARM_PATH   da    OPATHBUF
OCRPARM_ACC dfb   ACCESS_UNLKD
OCRPARM_TYPE   dfb   FTYPE_BIN
OCRPARM_AUX    da    0
OCRPARM_STORE  dfb   STYP_SEEDLING
OCRPARM_CDATE  da    0
OCRPARM_CTIME  da    0

ODPARM2      dfb   PCOUNT_OPEN
ODPARM2_PATH da    OPATHBUF
ODPARM2_IOBF da    $0000
ODPARM2_REF  dfb   0

OWPARM       dfb   PCOUNT_WRITE
OWPARM_REF   dfb   0
OWPARM_BUF   da    0
OWPARM_REQ   da    0
OWPARM_TRANS da    0

OCPARM       dfb   PCOUNT_CLOSE
OCPARM_REF   dfb   0

DEFOUT      asc   "LDOUT"
            dfb   0

NMRPARM       dfb   PCOUNT_READ
NMRPARM_REF   dfb   0
NMRPARM_BUF   da    0
NMRPARM_REQ   da    0
NMRPARM_TRANS da    0

GFIPARM      dfb   PCOUNT_GFI
GFIPARM_PATH da    0
GFIPARM_ACC  dfb   0
GFIPARM_FTYP dfb   0
GFIPARM_AUX  da    0
GFIPARM_STYP dfb   0
GFIPARM_BLKS da    0
GFIPARM_MDT  da    0
GFIPARM_MTM  da    0
GFIPARM_CDT  da    0
GFIPARM_CTM  da    0

MODOPARM      dfb   PCOUNT_OPEN
MODOPARM_PATH da    0
MODOPARM_IOBF da    $0000
MODOPARM_REF  dfb   0

MODRPARM       dfb   PCOUNT_READ
MODRPARM_REF   dfb   0
MODRPARM_BUF   da    0
MODRPARM_REQ   da    0
MODRPARM_TRN da    0
MODCHUNK       equ   512

* $E015/$E00C/$E018/$B240 stub-installation targets, as JMP
* patches (op byte + 2-addr-byte operand poked at startup --
* see START's own "JCLOSE/JRLOAD/ENTRY" section). Named as
* literal addresses (not labels into someone else's object), the
* same idiom asrom.s/as.s use for SENDMSG_STUB/WARMDIS.
JCLOSE_ADR  equ   $B20C
JRLOAD_ADR  equ   $B218
ENTRY_ADR   equ   $B240

*---------------------------------------------------------------
* Ceiling guard: everything above this line must fit below
* SYMADR ($2000) -- LINKER's own dictionary starts writing there
* the instant it runs.
*---------------------------------------------------------------
            ds    $2000-*

*---------------------------------------------------------------
* LINKWIN -- $2000-$2FFF, the window LINKER writes its
* DICTIONARY into, and the only part of `ld`'s image the
* linker may touch.
*
* WHY IT EXISTS (docs/STICKY.md sec 31). SYMADR is $2000 in the
* SHARED core object `as` also embeds, so LINKER's dictionary
* base is not `ld`'s to choose. The blobs used to start at $2000
* -- LINKER's dictionary grew straight through them and `ld`
* itself zeroed them once they were copied out -- which is fine
* until a loader stops recopying the image. Under lazy free the
* second `ld` of a boot got its own zeroed blobs back and
* failed.
* So the blobs move ABOVE the dictionary and this pad is what
* separates them. It costs image bytes but NO `ds` debt: a `ds`
* whose operand mentions `*` is a PC pad, not storage
* (scripts/check_purity.py's BIN_DEBT rule), and MODBUF leaving
* the image for the arena below pays for it twice over.
*
* WHY $1000 IS A PERFORMANCE KNOB AND NOT A CORRECTNESS ONE. The
* dictionary is ~2 B per module + 4 B per EXT fixup + each
* module's ENT/EXT name table (vendor/merlin/LINKER.S BUMPDIC/
* LOADEE), and nothing in the core bounds it below $BE00. If it
* ever outgrows this window it runs into the blobs -- which are
* DEAD by then, already copied to $D000/$E5F0/$FCA8, so THIS run
* is unaffected and its object is correct. Only the NEXT run
* would inherit a damaged image, and CHKBLOB (below) catches
* exactly that and refuses the bank, so the next run cold-loads
* and is correct too. Growing this pad buys warm-respawn
* eligibility for bigger links, nothing else. The hard cliff is
* far above: liba's own code starts past the blobs, ~14 KB up.
*---------------------------------------------------------------
LINKWIN
            ds    $3000-*
LINKWIN_LEN equ   *-LINKWIN

*---------------------------------------------------------------
* Embedded blobs -- the SAME process core and P6 stub blobs
* check-ascore-process/check-as already gate. Verbatim copies,
* each assembled AT its real target address, no relocation.
*
* THESE BYTES ARE READ-ONLY FOR THE WHOLE RUN, deliberately.
* They are this program's only copy of the core, and a warm
* respawn hands them back instead of reloading them, so anything
* that writes here breaks the NEXT invocation, not this one.
*---------------------------------------------------------------
CORE_BANK1
            putbin ../../build/ascore-process-bank1.obj
CORE_B1_LEN equ   *-CORE_BANK1

CORE_AS
            putbin ../../build/ascore-process-as.obj
CORE_AS_LEN equ   *-CORE_AS

STUBBLOB
            putbin ../../build/as-stubs.bin
STUB_LEN    equ   *-STUBBLOB

BLOB_LEN    equ   CORE_B1_LEN+CORE_AS_LEN+STUB_LEN

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* ld's own arena -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*` (sec 21;
* learning:01M0FNC75R7YSFRNS328WHXMHN).
*
* MODBUF is the module staging area: ONE module's whole REL
* file, front-loaded by LD_JRLOAD (this file's own header
* explains why). It was 4,096 EMITTED zero bytes at $4400
* until sec 31.
* sec 28 skipped `ld` because an arena that size ran past
* BUILDBASE ($6000) -- true while BUILDBASE was $6000, and
* BUILDBASE is `ld`'s own equate, seeded into SOURCE/ENDSRC by
* START. Moving it up to make room is one constant, and the
* `err */BUILDBASE` below is what keeps the two honest.
*
* NOTHING ZEROES THIS ARENA (docs/STICKY.md sec 21). MODBUF is
* filled by LD_JRLOAD's SC_READ loop before anything reads it,
* and every read of it is bounded by MODLEN/MODCODELEN, which
* that same loop set this run -- write-before-read, no zero
* start required.
*---------------------------------------------------------------
*-- MODBUF holds ONE MODULE'S DICTIONARY now, not a whole module
*-- (the code streams past in MODCHUNK slices). Measured across
*-- all 49 liba+kernel modules the largest dictionary is 2,060 B
*-- (cptree's) -- but that measured only the modules real Merlin
*-- builds. The UTIL MAINS the sweep generates are bigger: mv's
*-- is 2,323 B, and a cap sized on the first number failed MV
*-- and nothing else. $0B00 is 493 B over the real worst case,
*-- and is the whole span between the bridge stubs and Merlin's
*-- variable block. It was $1F00 when the
*-- staged-whole-module shape had to reserve 7,936. What that
*-- frees comes straight off BUILDBASE and goes into the build
*-- window, which is the point.
MODBUF_CAP  equ   $0B00
            dum   LIBA_BSSEND
MODDST      ds    2          ;streaming destination cursor
MODREM      ds    2          ;code bytes still to stream
MODAVL      ds    2          ;bytes of this chunk that may land
MODALW      ds    2          ;build-window allowance remaining
MODDICT     ds    2          ;dictionary bytes buffered so far
LDZVCNT     ds    2          ;copy-clamp zero-verify countdown
                             ;(written by the clamp before its
                             ;loop reads it -- sec 21)
* -- ARENA-END TRIPWIRE: `*` inside `dum` is this arena's end.
* -- It must stay below BUILDBASE, which is where LINKER starts
* -- accumulating the linked image. check_modules' image-window
* -- gate cannot see this -- a `dum` arena emits no bytes.
            err   */BUILDBASE
            dend

*---------------------------------------------------------------
* MODBUF LIVES ABOVE THE BUILD CEILING, not in the arena
* below it
* (S9 L5). Everything between the last bridge stub (AUXMOVE at
* $B260) and Merlin's own variable block (which starts at $BE00
* -- RWPARMS, DOSFNAM and the rest) is unused: 2,960 bytes of
* process bank nothing else claims.
*
* WHY IT MATTERS: the arena sits BETWEEN ld's image and
* BUILDBASE, so every byte in it is a byte the linked image
* cannot have. Moving the module buffer out from under
* BUILDBASE and up into dead space above BLDTOP hands its whole
* size back to the build window -- which is the difference
* between linking a kernel .SYSTEM image and not.
*
* It is SAFE ABOVE BLDTOP for the same reason BLDTOP exists: the
* image accumulates below $B200 and the clamp refuses to cross
* it, so nothing the linker writes can reach here.
*---------------------------------------------------------------
            dum   $B270
MODBUF      ds    MODBUF_CAP
*-- and it must all stay clear of $BE00, where Merlin's own
*-- RWPARMS/DOSFNAM block begins
            err   */$BE00
            dend
