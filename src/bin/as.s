*---------------------------------------------------------------
* as.s -- task #8 phase C/D: the maux Merlin-8 assembler front
* end. Full spec: docs/AS-DESIGN.md sections 1-4,7,13, docs/
* STICKY.md sec 31 (the warm-respawn cure, applied to `as` in
* phase D). Runs the WARM core (src/merlin/patches.py's
* WARM_GROUPS = P1w+P4+P5+P7+P10+P14, gated by
* check-ascore-warm) INSIDE a maux process -- neither of
* check-ascore's two artifacts: not the HARDWARE core
* (P1+P4+P5+P7 only, differs by P10, the RAMRD/RAMWRT class
* removal section 13 ruled -- P9 was dropped entirely, section
* 14) and not the PROCESS core `ld.s` embeds either
* (P1+P4+P5+P7+P10+P14, SYMADR=$2000 -- LINKER's own dictionary
* free ride, docs/STICKY.md sec 31, and so may not move). WARM
* is PROCESS with exactly one equate changed: SYMADR moved from
* $2000 to ABOVE this file's own image end (P1w vs
* P1's own P1_SYMADR_LOW, src/merlin/patches.py), so a warm
* respawn's un-recopied blob bytes can never overlap the symbol
* table -- see the SYMADR equate's own comment, below, and the
* MEMORY LAYOUT table right here for the full argument. See
* patches.py for the complete patch set this front end assumes.
*
* CLI: as [-l] [-o objfile] srcfile. Diagnostics "as: ..." to
* stderr. Exit 0 iff zero assembly errors, 1 on any runtime/
* assembly failure, 2 on a usage error.
*
* MEMORY LAYOUT (this file's own ruling, re-deriving AS-DESIGN
* section 1 from the phase-D artifacts' REAL, measured sizes --
* build/as.bin is 11,575 bytes at $0800, ending at $3537):
*   $0800-$089F   entry jmp + MACASS.S's own exclusion zone (see
*                 that comment, below) -- RESTHEAD (below
*                 FINDEXIT) restores this on every exit, since
*                 MACASS.S's own ASM entry zeros it every run.
*   $08A0-$3537   this front end: code, PERSISTENT data (argv
*                 pointers, LFLAG/OFLAG, the exit trampoline),
*                 THEN the three embedded blobs (core bank1,
*                 core AS, ROM stubs, 9,095B combined -- copied
*                 out to their real addresses during startup and
*                 READ-ONLY thereafter, see their own comment
*                 below), THEN liba. NO PAD before the blobs
*                 (task #8 phase D removed the old $2000-aligned
*                 ceiling pad that used to force them there) --
*                 they pack immediately after the front-end
*                 code/data.
*   $3537-$39B4   liba's OWN bss arena (`dum`/`dend`, src/liba/
*                 libabss.s -- SIO_STAGE, RD_DIRBUF, ... -- real
*                 process memory, no disk bytes). LIBA_BSSEND is
*                 $39B5 here, NOT the raw image end -- measured,
*                 not assumed (see the SYMADR equate's own
*                 comment for the bug this caught).
*   ..$3C06      this file's own tiny arena (`dum LIBA_BSSEND`,
*                 at the textual end): BLOBSIG, then AS_GOREAD's
*                 RDX_* scratch. It ENDS at $3C06 today; the
*                 exact addresses move with every byte added to
*                 this file, which is the whole point of the two
*                 `err` guards down there rather than a number
*                 written here.
*   $4000         SYMADR (this file's own equate, below -- MUST
*                 match src/merlin/patches.py's P1_SYMADR_HIGH,
*                 and check_ascore.check_symadr_agrees fails the
*                 build if they drift). Page-aligned, and 250
*                 bytes above the arena's end as measured on
*                 2026-08-28 by widening BLOBSIG until the guard
*                 fires (`ds 253` builds, `ds 254` does not).
*                 Symbol table grows up from here. Was $3C00
*                 until the AS_GOREAD work spent 134 image bytes
*                 and four arena cells and crossed it -- see
*                 docs/AS-PUT.md. $3D00 -> $4000 on 2026-08-28:
*                 liba's stage-owner buffering grew SIO_STAGE
*                 512 -> 1024 (+537 arena bytes with the
*                 geometry tables), and the `err` guards below
*                 fired exactly as designed. Costs the symbol
*                 window $300: SYMADR..SRC_BASE is $2000
*                 (8,192B) now. NOTHING of this file's own
*                 image OR bss reaches this address or above --
*                 the `err` guards at this file's own end
*                 enforce it, and unlike the OLD $2000 layout,
*                 nothing here is ever the arena's own copy
*                 SOURCE, so ZEROFILL clearing it (see that call
*                 site) can never zero anything still needed.
*   $6000-$9FFE   SOURCE window (this file's SRC_BASE) -- arena
*                 is SYMADR..SRC_BASE-1, $2300 (8,960B), LARGER
*                 than the old effective ~9,095B (the blobs used
*                 to eat into this same window until BLOCKCP
*                 consumed them; they no longer share it at
*                 all).
*   $9FFF         HIMEM.
*   $A000-        OBJECT (OBJPNT, core-hardcoded every run, P11-
*                 moved from $8000). Read back after ASEXIT,
*                 never written by this front end.
*   $D000-$F879   assembler core (LC, copied in at startup).
*   $FCA8-$FDF5   the P6 ROM stubs (copied in at startup).
*
* DEVIATION from AS-DESIGN's P8 (recorded here, not just in the
* task report -- the next reader of this file needs it too): NO
* $BF00 MLI bridge is installed. DIRFLG stays clear (P7's
* neutered SAV/DSK dispatch never sets it, and this front end
* never does either), so DODSK's JMLI streaming path -- the only
* reason P8 was proposed -- is provably unreachable (grepped
* every embedded module; DIRFLG is touched nowhere else). This
* also sidestepped a real wall AT THE TIME: maux's own kernel
* (src/kernel/procfile.s PRC_FILECALL) did not implement
* SET_MARK/SET_EOF/SET_FILE_INFO at all, which DODSK and
* ASSMAIN's DIRFLG-gated CLOSE cleanup would both need.
* CORRECTED 2026-08-25: all three ARE dispatched now
* (procfile.s:34-49; SC_SFI/SC_SETMARK/SC_SETEOF in
* src/liba/syscalls.s, gated by check-chmod and check-seek), so
* the WALL is gone and only the DESIGN CHOICE remains. The
* choice still stands on its own merits -- see the paragraph
* below -- but it is now a preference, not a necessity, and
* anyone re-opening DODSK should know the calls exist.
* Instead: `as` leaves the object
* in its normal in-memory buffer (the same path check-ascore's
* phase-B (b) already proved byte-identical) and, on success,
* copies it out itself with ordinary liba OPEN/WRITE/CLOSE --
* -o is therefore a POST-assembly step, not disk streaming
* during pass 2.
*
* DEVIATION: KEYVEC (aux-ZP $AE/$AF) is NOT set. AS-DESIGN's P4
* amendment calls for it, but GOKEYV/GOGETKEY/KEYVEC appear
* NOWHERE in the embedded chain (ASSMAIN/ASS.BNK1/GETLINE/
* SYMPRINT/BRACKET/PRINTENT/OPCODES/COMMANDS/MSGS, LINKER
* dormant) -- grepped exhaustively. Those symbols are MACED-
* only, and MACED is never embedded (AS-DESIGN's own P4 ruling).
* CSW/KSW ARE still set (defensively -- see COUT's own note
* below for why they are provably never dereferenced either).
*
* ALTZP resolution (task's own open question): a maux process
* IS its aux bank -- BANKSEL ($C073) plus ALTZP are already
* engaged by the scheduler before ANY of this code runs (see
* src/kernel/sched.s's SCH_SWITCH). Every zero-page cell this
* file touches (SOURCE/HIMEM/ENDSRC at $0A-$0F, ERCOUNT $1D,
* DUPCNT $89, DIRFLG $B2, PAGFLAG $A2, CSW/KSW $36-$39) is
* therefore ALREADY this process's own private copy -- no
* softswitch flip is needed or performed here, matching every
* other util in src/bin (ls.s, cat.s, ...) that never touches
* ALTZP/RAMRD/RAMWRT either.
*---------------------------------------------------------------
            lst   off
            xc
            org   LOAD_BASE
            dsk   ../../build/as.bin
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

* -- core-fixed zero-page cells (MACASS.S equates -- this front
* -- end never redefines these, only reads/writes at the SAME
* -- addresses the core itself uses) --
ASM_ENTRY   equ   $E5F3
SRC_BASE    equ   $6000
HIMEM_VAL   equ   $9FFF        ;P11: OBJPNT-1, was $7FFF
* SYMADR -- task #8 phase D (docs/STICKY.md sec 31's cure,
* applied to `as`): the core's OWN symtab base, baked into the
* embedded blobs below as immediate operand bytes at build time
* (src/merlin/patches.py's P1_SYMADR_HIGH patches MACASS.S's own
* equate). This copy is for THIS file's own use (the ZEROFILL
* target below, the ceiling `err` near this file's end) and MUST
* be kept numerically equal to that patch's value by hand -- two
* different translation units, core assembled separately into
* build/ascore-warm-*.obj and `putbin`'d verbatim below. Page-
* aligned (learning:01M0CY18ZDXAJQH2NFFGG2NN36 -- ASS.BNK1.S's
* `LDY #SYMADR ;=0` idiom needs the low byte literally 0).
*
* NOT simply "above the raw image end" -- measured wrong once
* (this file's own build, task #8 phase D): `$3800` cleared the
* 11,575-byte image ($0800-$3537) with 713B to spare but landed
* SQUARELY inside src/liba/libabss.s's own bss arena, which this
* file (like every other program that puts liba) carries PAST
* the image end -- LIBA_BSSEND is $39B5 here, not $3537, because
* liba's own uninitialised storage (SIO_STAGE, RD_DIRBUF, ...)
* occupies that whole span too, real process memory even though
* it costs no DISK bytes (docs/STICKY.md sec 21's `dum` idiom).
* SYMADR inside that span would let the growing symbol table
* silently overwrite liba's OWN buffers the moment PUTLAB wrote
* a label -- corrupting, among other things, WRITEOBJ's own
* liba calls, which run AFTER assembly and would then read back
* garbage. SYMADR must clear LIBA_BSSEND, not just the image --
* found by measuring merlin32's own symbol dump (-v0), not
* inferred; see the file header's MEMORY LAYOUT table.
SYMADR      equ   $4000
Z_SOURCE    equ   $0A
Z_HIMEM     equ   $0C
Z_ENDSRC    equ   $0E
Z_ERCOUNT   equ   $1D
Z_CSWL      equ   $36
Z_CSWH      equ   $37
Z_KSWL      equ   $38
Z_KSWH      equ   $39
Z_DUPCNT    equ   $89
Z_PAGFLAG   equ   $A2
Z_DIRFLG    equ   $B2
Z_OBJPNT    equ   $E2
Z_OBLEN     equ   $E4
Z_ASMPNT    equ   $EC        ;MACASS.S:176, seed comment below
Z_CODELEN   equ   $86        ;MACASS.S:123 -- code-only length
                             ;when REL is active (ADDREL parks
                             ;it before the dictionary is sent)
Z_RELFLAG   equ   $8F        ;MACASS.S:131 -- minus after the
                             ;source's own REL directive; core
                             ;zeroes it at every ASM entry
CORE_D000   equ   $D000
CORE_E5F0   equ   $E5F0
GOREAD_STUB equ   $E021          ;core's PUT/USE file-read hook
                                 ;-- unstubbed in v1, and every
                                 ;maux unit puts something
                                 ;(docs/AS-PUT.md)
Z_PUTFLG    equ   $05            ;core ZP: minus while in a PUT
Z_PUTSP     equ   $08            ;core ZP: the PUT load address,
                                 ;set to ENDSRC+1 by the handler
WORKSP      equ   $0280          ;core: FIXNAME leaves the put
                                 ;filename here, $8D-terminated
SENDMSG_STUB equ  $E033
SENDMSG_IMPL equ  $FDF5           ;asrom.s -- inline-string
                                  ;printer, NOT a bare RTS (see
                                  ;that file's own SENDMSG_IMPL
                                  ;comment)
* Section 11's state-diff (docs/AS-DESIGN.md) cross-referenced
* MACASS.S's OWN complete $E0xx equate list (NUMCOL/BYTLINE/
* ASSERR/LSTDODFT/HORIZ/WARMDIS/GOREAD/GOSAVE/JBELL/SENDMSG --
* every $E0xx cell the core chain actually names) against every
* embedded-file call/read site. GOREAD/GOSAVE are PUT/USE-only
* (ASS.BNK1.S's own USE/PUT handler) -- unreached by any v1 test
* source, out of scope per AS-DESIGN section 0's own PUT-chain
* exclusion, left untouched. WARMDIS and JBELL are TWO MORE
* resident-block entries P6's six-monitor-ROM recon and even the
* 2026-08-20 SENDMSG fix missed.
Z_NUMCOL    equ   $E011
Z_BYTLINE   equ   $E016
Z_ASSERR    equ   $E017
Z_LSTDODFT  equ   $E019
Z_HORIZ     equ   $E01A
Z_WARMDIS   equ   $E01B
Z_JBELL     equ   $E027
SCANBASE    equ   CORE_E5F0-2
STUB_FCA8   equ   $FCA8
ROM_COUT    equ   $FDED
ROM_GETLN2  equ   $FD6F

*---------------------------------------------------------------
* START -- argv parse, load+transform source, embed the core,
* set the entry contract, jump in. Never returns; MYEXIT (below)
* is where control comes back, via the poked ASEXIT redirect.
*---------------------------------------------------------------
            jmp   START

* $0800-$089F EXCLUSION ZONE -- found by tracing a live crash,
* not in any doc: MACASS.S's own macro-level-tracking storage
* (`DUMMY $800 / MPASS DS MX / MSAV ... / LVPNT DS MX*2 /
* ERR *-$8A0 / DEND`) is a DUM block anchored at the LITERAL
* address $800 -- LOAD_BASE, where every maux process's own
* code starts. ASM's own entry point (MACASS.S:3-8, its SECOND
* action after `JSR BNK1`) unconditionally zeroes MPASS ($800-
* $80F) every run, macros or not, and MSAV/ADSV/MADSV/PNSV/
* LVPNT (through $89F) whenever macros ARE used. This front end
* cannot move LOAD_BASE (kernel-mandated spawn entry), so
* instead nothing of its own past the entry jmp may live below
* $8A0 -- this `ds` pushes AS_PUTCH (and everything else) clear
* of it. The 3-byte `jmp START` above is exempt: it only needs
* to survive long enough to run once, before ASM_ENTRY.
            ds    $8A0-*

* as.s's own char-output helper, fixed at $08A0 (the first safe
* byte past the exclusion zone above) -- asrom.s's COUT stub
* JSRs here by that literal address, having no visibility into
* this file's labels.
AS_PUTCH    ldy   LFLAG
            beq   :skip
            ldx   #FD_STDOUT
            jsr   PUTC
:skip       rts

            put   asboot.s
* INLINE-STRING call -- `JSR SENDMSG` is ALWAYS immediately
* followed by a NUL-terminated, high-bit ASC/HEX/DFB literal
* (e.g. GETLINE.S:121 `DONE JSR SENDMSG / HEX A08DA08D / ASC
* "--End assembly, "00`), the same idiom the real ROM's
* string-printing routines use. A bare RTS returns to the
* FIRST BYTE OF THAT STRING and the CPU executes it as code.
* This was diagnosed the hard way: after the bare-RTS stub,
* `as` progressed past the original $E033 BRK only to BRK
* again at $F5D5 inside CORE_AS -- byte-verified against
* build/ascore-as.obj to be the EXACT NUL terminator of
* DONE's own "--End assembly, " string (BYTPRN's
* ERCOUNT/DUPCNT/PRDEC+2 tail sits at $F5B5-$F5BD immediately
* before it). Same bug, second occurrence, not two bugs.
*
* SENDMSG_IMPL (src/bin/asrom.s) is the real fix: prints the
* inline string via COUT (so it also respects -l) then
* patches the return address on the hardware stack to land
* just past the NUL, exactly what MACED.S's own TXTP-driven
* SENDMSG achieves, minus the tab/cursor machinery a headless
* front end has no use for.
*
* MUST be a JMP, not a JSR: SENDMSG_IMPL reads the CALLER's
* own pushed return address directly off the stack (that's
* how it finds the inline string) -- a JSR here would push a
* THIRD address (this stub's own $E033 call) on top of it, so
* SENDMSG_IMPL would pull ITS OWN stub-internal return
* address instead of the real caller's, find garbage/an empty
* "string", and return to the wrong place (caught live: with
* JSR here the very first SENDMSG call landed a BRK at $E037,
* one byte into this stub's own dead $E036+ padding -- not a
* caller's real inline string at all).
            lda   #<SENDMSG_IMPL
            sta   SENDMSG_STUB+1
            lda   #>SENDMSG_IMPL
            sta   SENDMSG_STUB+2
            lda   #$4C               ;JMP
            sta   SENDMSG_STUB

* GOREAD stub ($E021, 2026-08-28): the core's USE/PUT handler
* (ASS.BNK1.S) does `JSR GOREAD` to load the named file. v1 left
* it unstubbed because no v1 test source used PUT -- but every
* real maux unit puts liba at minimum, so `as` could not
* assemble one line of this tree until this existed. Same
* unbanked $E000-$E5EF gap and the same JMP shape SENDMSG uses
* above; a JMP, not a JSR, is not required here (AS_GOREAD reads
* no inline data) but matches the stub idiom and costs nothing.
            lda   #<AS_GOREAD
            sta   GOREAD_STUB+1
            lda   #>AS_GOREAD
            sta   GOREAD_STUB+2
            lda   #$4C               ;JMP
            sta   GOREAD_STUB

* WARMDIS ($E01B) / JBELL ($E027) -- both JSR'd as PLAIN
* subroutine calls (no inline data, no stack tricks, unlike
* SENDMSG): WARMDIS sits between a PHA/PLA at ASS.BNK1.S:1037-
* 1039 (interactive KBD-value-request path, unreached -- no
* test source uses KBD) and, unconditionally, in SYMPRINT.S's
* OUT tail (:16-20 -- COUT / JSR WARMDIS / BIT STROBE / BIT
* CONTROL / JMP EDITOR-as-ASEXIT) that EVERY assembly falls
* through on its way out (GETLINE.S DONE -> SYMPRINT, no branch
* skips OUT). JBELL/BELL is JSR'd from ASS.BNK1.S's error-
* report path (:901, reached by any source WITH an error --
* src/test/asbadmod.s does) and its own KBD path (unreached,
* same as WARMDIS's). Neither call site branches on a return
* value or register WARMDIS/JBELL might set (WARMDIS: PLA
* right after re-loads A from the stack regardless; JBELL: the
* next instruction runs unconditionally either way) -- MACED.S's
* own real handlers are pure UI (a "warm display" redraw, a
* speaker click), meaningless headless, the SAME "correct, not
* merely expedient" reasoning already used for P6's MONWAIT/
* GETLN2 no-ops. Bare RTS, not a JMP -- these ARE the routine,
* no string/data follows.
            lda   #$60               ;RTS
            sta   Z_WARMDIS
            sta   Z_JBELL

* Five more $E0xx DATA cells the core reads but this front end
* never (re)writes before use. LSTDODFT is copied into the live
* LSTDOFLG at the VERY START of ASM's own entry (ASSMAIN.S:54-
* 55 -- inside the SAME routine this file's own `jmp ASM_ENTRY`
* below lands in). BYTLINE is the hottest of the five: ASS.
* BNK1.S's PRCODE (the per-OBJECT-BYTE emit routine, called
* once per assembled byte) does `SBC BYTLINE` EVERY byte to
* drive its column/TABCNT bookkeeping, gated only by LIST? --
* which returns "proceed" in BOTH the working and direct
* configurations alike, since every cell LIST? itself tests
* (ZMDO/DOFL/LSTDOZ/MPASS/EXPFLG/LSTFLG) is entry-zeroed
* identically either way (confirmed via the section-11 ZP
* capture). An uninitialized BYTLINE therefore feeds bad
* arithmetic into that on EVERY byte of a real assembly, not
* just at completion -- the leading candidate for the multi-
* billion-cycle hang this section addresses. NUMCOL/HORIZ feed
* SYMPRINT's listing-column tabs (BEGIN's `MOV NUMCOL;TAB`, the
* "print time" HORIZ/DOHTAB path); ASSERR is read via a plain
* BIT whose only consumer (ERRWAIT) P4 already neuters into an
* unconditional JMP, so its value cannot affect control flow --
* seeded anyway, cheap, for a clean diff. Values are the LIVE
* bytes a WORKING run (MACED's own `L`/`ASM` entry) actually
* has at ITS OWN $E5F3 arrival -- captured by scripts/
* capture_e5f3_state.py into build/e5f3_working.json, per docs/
* AS-DESIGN.md section 11 -- not hand-derived from the MACED.S
* disk-template defaults, which the live system no longer
* matches by the time assembly proper begins (confirmed:
* ASSERR's live byte is nowhere near its DFB-5 template default
* either).
            lda   #$C0
            sta   Z_NUMCOL
            lda   #$03
            sta   Z_BYTLINE
            lda   #$9C
            sta   Z_ASSERR
            lda   #$C0
            sta   Z_LSTDODFT
            lda   #$AD
            sta   Z_HORIZ

            jsr   FINDEXIT
            lda   ASEXITAD
            ora   ASEXITAD+1
            bne   :havexit
            lda   #<NOEXIT
            ldx   #>NOEXIT
            jsr   DIAG1
            lda   #1
            jsr   PREEXIT
:havexit    lda   ASEXITAD
            sta   PTR0
            lda   ASEXITAD+1
            sta   PTR0+1
            ldy   #0
            lda   #$4C               ;JMP
            sta   (PTR0),y
            iny
            lda   #<MYEXIT
            sta   (PTR0),y
            iny
            lda   #>MYEXIT
            sta   (PTR0),y

*---------------------------------------------------------------
* Entry contract (docs/AS-DESIGN.md section 1, the phase-B
* evidence): SWEET-16 R0/R1/R2 zeroed, R5/R6/R7 = SOURCE/HIMEM/
* ENDSRC, PAGFLAG negative, DIRFLG clear (P7 already guarantees
* this is never SET reachably; cleared here defensively too),
* CSW/KSW pointed at the P6 COUT stub (defense in depth -- no
* core code was found to dereference them, see file header).
*---------------------------------------------------------------
            stz   $00
            stz   $01
            stz   $02
            stz   $03
            stz   $04
            stz   $05
            lda   #<SRC_BASE
            sta   Z_SOURCE
            lda   #>SRC_BASE
            sta   Z_SOURCE+1
            lda   #<HIMEM_VAL
            sta   Z_HIMEM
            lda   #>HIMEM_VAL
            sta   Z_HIMEM+1
            lda   ENDSRCLO
            sta   Z_ENDSRC
            lda   ENDSRCHI
            sta   Z_ENDSRC+1
* FPHI (aux-ZP $73, "Absolute himem") -- found by tracing a
* live crash: ASM's own entry (ASSMAIN.S:65-66, right after the
* SOURCE->SPNT copy) does `LDA FPHI,X / STA HIMEM,X` for BOTH
* bytes, UNCONDITIONALLY overwriting the R6/HIMEM value just
* set above with whatever garbage sits at $73/$74 in a freshly
* allocated process bank. MACED's own VALID routine (never run
* here) is what normally seeds FPHI FROM Himem first; this
* front end must seed it directly.
            lda   #<HIMEM_VAL
            sta   $73
            lda   #>HIMEM_VAL
            sta   $74
* ASMPNT (aux-ZP $EC) re-seeded to $A000 too, matching OBJPNT
* (P11-moved from $8000): ASSMAIN.S:75's `RES TRDB
* OBJPNT;ASMPNT` (unconditionally reached, `BNE RES ;Always`
* at :70) sets ASMPNT FROM OBJPNT (TRDB's dest is its SECOND
* operand -- confirmed against GETLINE.S:2's `TRDB SPSAV;SPNT`,
* "restores the source pointer", i.e. SPNT := SPSAV, per
* docs/SELFHOST.md), which ASSMAIN.S:22-24 already set moments
* earlier -- so this alone was NOT bug 4's cause (chased first,
* ruled out: this seed alone left the object write unchanged,
* still garbage). The REAL cause was a zero-page COLLISION in
* WRITEOBJ below, not a missing core seed -- see that routine's
* own comment. Left here, harmless and cheap, since ASMPNT is
* otherwise whatever a fresh process bank happens to contain
* until RES runs.
            stz   Z_ASMPNT
            lda   #$A0
            sta   Z_ASMPNT+1
            lda   #<ROM_COUT
            sta   Z_CSWL
            lda   #>ROM_COUT
            sta   Z_CSWH
            lda   #<ROM_GETLN2
            sta   Z_KSWL
            lda   #>ROM_GETLN2
            sta   Z_KSWH
            lda   #$80
            sta   Z_PAGFLAG
            stz   Z_DIRFLG
            jmp   ASM_ENTRY

*---------------------------------------------------------------
* MYEXIT -- landed here via the poked ASEXIT redirect. ERCOUNT +
* DUPCNT (both in THIS process's own zero page -- see the file
* header's ALTZP note) is the error count; -o writes the object
* out only on a clean assembly.
*---------------------------------------------------------------
MYEXIT      lda   Z_ERCOUNT
            clc
            adc   Z_DUPCNT
            beq   :clean
            lda   #<ASMFAIL
            ldx   #>ASMFAIL
            jsr   DIAG1
            lda   #1
            jsr   PREEXIT
:clean      lda   OFLAG
            beq   :done
            jsr   WRITEOBJ
            bcc   :done
            lda   #<WRFAILSUF
            sta   DG_SUFLO
            lda   #>WRFAILSUF
            sta   DG_SUFHI
            lda   #<OBJPTR
            ldx   #>OBJPTR
            jsr   DIAG2
            lda   #1
            jsr   PREEXIT
:done       lda   #0
            jsr   PREEXIT

*---------------------------------------------------------------
* WRITEOBJ -- create/open OBJPTR's path, write OBLEN bytes
* starting at OBJPNT (the core's own in-memory object buffer --
* never touched by this front end until now), close.
* OUT: carry clear = ok, carry set = a call failed.
*
* Z_OBJPNT/Z_OBLEN MUST be captured BEFORE any liba call below:
* liba's own PTR1 ($E2)/PTR2 ($E4) -- see inc/zp.equ --
* are the IDENTICAL zero-page addresses as the core's OBJPNT/
* OBLEN (MACASS.S:169-170). Found live (task #8 phase C, docs/
* AS-DESIGN.md section 14): a "byte-identical" GOODMOD.OBJ write
* was instead 3467-3473B and began with a length-prefixed
* pathname string -- MKPATH below (called with PTR1=PATHBUF,
* i.e. $E2 := <PATHBUF) and its own internal PTR2 use both
* clobber the very cells this routine reads afterward, so by the
* time the old code did `LDA Z_OBJPNT`, that cell no longer held
* the object's address at all -- it held PATHBUF's. Same root
* SHAPE as the SENDMSG/FPHI/ASMPNT findings (an assumption one
* call satisfies breaking a LATER one), but this one is a plain
* zero-page collision between this file's own liba use and the
* core's private state, not a missing entry-contract seed.
*---------------------------------------------------------------
* AS_GOREAD -- service the core's `JSR GOREAD` ($E021), i.e.
* load a PUT file. Reverse-engineered contract, docs/AS-PUT.md:
*
*   IN   WORKSP ($0280) = the filename, high-bit ASCII,
*        $8D-terminated (FIXNAME overwrote the first space).
*        Z_PUTSP ($08) = where to load it; the handler set both
*        SPNT and PUTSP to ENDSRC+1 before calling.
*   OUT  X < 14. The caller does `CPX #14 ... BLT JMPR0`, so a
*        larger X falls into MEMERR.
*
* IT MUST WRITE A $00 AFTER THE TEXT, and that is the whole
* reason a PUT ever ends: GETLINE.S fetches with `MVLN LDA
* (SPNT,X) / BEQ ENDPUT`, and ENDPUT is what restores SPNT from
* SPSAV and resumes the parent file. Without the terminator the
* assembler reads straight past the put into whatever follows.
* ($FF ends the WHOLE assembly -- a different marker.)
*
* ENDSRC IS DELIBERATELY NOT ADVANCED. Each put loads at
* ENDSRC+1, so the next one reuses the same region and a chain
* costs the buffer its LARGEST member rather than their sum.
* That is the mechanic check_dialect.py budget 3 models, and
* correcting AS-DESIGN's A4 (which described USE) is what showed
* the tree could be split with put directives at all.
*
* THE ZERO PAGE IS THE HAZARD, and this file has already been
* bitten by it once: liba's PTR1/PTR2/OPTPTR ($E2/$E4/$EC) ARE
* the core's OBJPNT/OBLEN/ASMPNT. WRITEOBJ below parks OBJPNT
* for exactly this reason, after a "byte-identical" object write
* came out as a length-prefixed pathname. That collision was
* survivable because it happened between assemblies; this
* routine runs DURING one, so it parks all three and restores
* them before returning to the core.
*
* File I/O mid-assembly is reachable at all because neither core
* blob covers the $FFxx page maux's syscall stubs live in
* (CORE_BANK1 $D000-$DFCC, CORE_AS $E5F0-$F831). P7 made the
* front end own the object write, which happens after the
* assembly -- so nothing had ever needed this before.
*---------------------------------------------------------------
AS_GOREAD   lda   PTR0             ;PTR0 is not in the core's
            pha                      ;own ZP set, but save it
            lda   PTR0+1             ;anyway -- this file has
            pha                      ;already been bitten once
*-- The load address the handler prepared, into a ZERO-PAGE
*-- pointer because the transform below is (PTR0),y indexed.
            lda   Z_PUTSP
            sta   PTR0
            lda   Z_PUTSP+1
            sta   PTR0+1
*-- Build the MLI pathname straight from WORKSP: length byte
*-- then 7-bit characters. No MKPATH -- the staged image gives
*-- absolute paths (build_maux_src_image.py rewrites every put
*-- line to `PUT /mnt/MAUXSRC/SRC/NAME`), so there is no cwd to
*-- resolve against, and skipping it keeps liba's PTR1/PTR2 --
*-- which ARE the core's OBJPNT/OBLEN -- entirely out of this.
            ldy   #0
:cpname     lda   WORKSP,y
            cmp   #$8D
            beq   :namedone
            and   #$7F
            sta   PATHBUF+1,y
            iny
            cpy   #64
            bcc   :cpname
:namedone   sty   PATHBUF
            lda   #<OPARM
            ldx   #>OPARM
            jsr   SC_OPEN
            bcs   :fail
            lda   Z_HIMEM+1
            sta   RDX_BOUND
            lda   OPARM_REF
            jsr   RDXFORM
            bcs   :ioerr
*-- THE TERMINATOR, and the whole reason a put ever ends:
*-- GETLINE.S reads with `MVLN LDA (SPNT,X) / BEQ ENDPUT`, and
*-- ENDPUT restores SPNT from SPSAV and resumes the parent.
:rddone     jsr   GRD_CLOSE
            lda   #0
            ldy   #0
            sta   (PTR0),y
            ldx   #0
            beq   :out              ;always -- ldx set Z
:ioerr      jsr   GRD_CLOSE
:fail       ldx   #14               ;>= 14 -> the core's MEMERR
:out        pla
            sta   PTR0+1
            pla
            sta   PTR0
            rts

GRD_CLOSE   lda   RDX_FD           ;RDXFORM parked the fd; one
            sta   CPARM_REF        ;cell, not two
            lda   #<CPARM
            ldx   #>CPARM
            jmp   SC_CLOSE


*---------------------------------------------------------------
            put   asxform.s
* BLOCKCP -- IN PTR0=src, PTR1=dst, CPLEN=length (2 bytes, must
* be > 0). Plain byte copy, no page-boundary shortcuts needed --
* this runs once per blob at startup, not per assembled byte.
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

*---------------------------------------------------------------
* ZEROFILL -- IN PTR0=dst, CPLEN=length (2 bytes, must be > 0).
* Same shape as BLOCKCP above but stores a constant 0 -- used
* once, at startup, to re-establish the SYMADR zero invariant
* (see the call site's own comment).
*---------------------------------------------------------------
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
* FINDEXIT -- scan CORE_E5F0..CORE_E5F0+CORE_AS_LEN-3 (already
* copied into place) for a 3-byte self-jump (JMP <its own addr>)
* -- P5's ASEXIT landing pad, discovered fresh every run per
* docs/AS-DESIGN.md's own open risk, never hardcoded. OUT:
* ASEXITAD = the address found, or 0 if none.
*---------------------------------------------------------------
FINDEXIT    lda   #<CORE_E5F0
            sta   PTR0
            lda   #>CORE_E5F0
            sta   PTR0+1
            clc
            lda   #<CORE_AS_LEN
            adc   #<SCANBASE
            sta   SCANEND
            lda   #>CORE_AS_LEN
            adc   #>SCANBASE
            sta   SCANEND+1
:loop       lda   PTR0+1
            cmp   SCANEND+1
            bne   :cont
            lda   PTR0
            cmp   SCANEND
            beq   :notfnd
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
            lda   PTR0
            sta   ASEXITAD
            lda   PTR0+1
            sta   ASEXITAD+1
            rts
:next       inc   PTR0
            bne   :loop
            inc   PTR0+1
            bra   :loop
:notfnd     stz   ASEXITAD
            stz   ASEXITAD+1
            rts

*---------------------------------------------------------------
* PREEXIT -- task #8 phase D (docs/STICKY.md sec 31's cure,
* applied to `as`). Every one of this file's own `jsr EXIT`
* sites now reads `jsr PREEXIT` instead -- a single funnel, so
* EVERY exit path (success, assembly-error, and each startup/
* runtime failure) gets the same housekeeping with no risk of a
* forgotten site. RESTHEAD then CHKBLOB, in that exact order:
* CHKBLOB's own STAMPHEAD must be the LAST write to the entry
* head, so a corrupted-blob verdict can never be silently undone
* by RESTHEAD's own restore (see CHKBLOB's own header). A is the
* caller's exit status; PREEXIT preserves it across both calls
* and tail-jumps into the real EXIT (liba, src/liba/stdio.s,
* never returns) instead of JSR+RTS -- one exit, not two.
*---------------------------------------------------------------
PREEXIT     pha
            jsr   RESTHEAD
            jsr   CHKBLOB
            pla
            jmp   EXIT

*---------------------------------------------------------------
* RESTHEAD -- restore LOAD_BASE's entry head to match the FILE
* on disk, on every exit. MACASS.S's own ASM entry (this file's
* own EXCLUSION ZONE comment, near the top) unconditionally
* zeros $800-$80F every run and $810-$89F whenever the assembled
* source used a macro -- squarely inside the 8 bytes the
* kernel's own LZ_RETAIN checks (src/kernel/lazyfree.s) -- so
* without this `as`'s bank is refused retention on EVERY exit
* and the next spawn cold-loads the whole image regardless of
* anything else this file does. Symbolic, never literal bytes,
* for the jump TARGET (this file's own convention -- see the
* ASEXIT redirect, above); only the JMP opcode itself ($4C) is a
* true literal, same as that same redirect.
*---------------------------------------------------------------
PADSTART    equ   LOAD_BASE+3
PADLEN      equ   $8A0-PADSTART
RESTHEAD    lda   #$4C               ;JMP
            sta   LOAD_BASE
            lda   #<START
            sta   LOAD_BASE+1
            lda   #>START
            sta   LOAD_BASE+2
            lda   #<PADSTART
            sta   PTR0
            lda   #>PADSTART
            sta   PTR0+1
            lda   #<PADLEN
            sta   CPLEN
            lda   #>PADLEN
            sta   CPLEN+1
            jsr   ZEROFILL
            rts

*---------------------------------------------------------------
* CHKBLOB / STAMPHEAD -- the backstop, transplanted from ld.s
* (docs/STICKY.md sec 31, "CHKBLOB / STAMPHEAD -- the backstop
* under LINKWIN's size"). Unlike `ld`, this SHOULD NEVER FIRE:
* with SYMADR moved above this file's own image end (the file
* header's MEMORY LAYOUT table), the growing symbol table can no
* longer reach the blob bytes AT ALL -- there is no LINKWIN-
* sized window inside the image for it to overrun. It stays as
* defense in depth anyway, through the SAME detector the kernel
* already has (LZ_RETAIN's own head compare): if BLOBSIG ever
* stops matching CORE_BANK1's live first three bytes, for any
* reason this file's own reasoning missed, STAMPHEAD clears
* LOAD_BASE's own first byte so the kernel refuses to retain the
* bank and the NEXT `as` of the boot cold-loads a clean image
* instead of inheriting the wreckage.
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
* DIAG1 -- IN A/X=<//> a NUL-terminated liba message; prints
* "as: " + message + CR to stderr.
            put   asdiag.s
* selected -- which, under this front end's own entry contract,
* is always this process's own bank. P1w is P1 with SYMADR moved
* to this file's own SYMADR equate (above) instead of $2000 --
* the ONE difference from the core `ld.s` embeds.
CORE_BANK1
            putbin ../../build/ascore-warm-bank1.obj
CORE_B1_LEN equ   *-CORE_BANK1

CORE_AS
            putbin ../../build/ascore-warm-as.obj
CORE_AS_LEN equ   *-CORE_AS

STUBBLOB
            putbin ../../build/as-stubs.bin
STUB_LEN    equ   *-STUBBLOB

            put   ../liba/string.s
            put   ../liba/mli.s
            put   ../liba/stdio.s
            put   ../liba/stdiofl.s
            put   ../liba/print.s
            put   ../liba/argv.s
            put   ../liba/syscalls.s
            put   ../liba/libabss.s

*---------------------------------------------------------------
* as's own arena -- `dum`/`dend` at the TEXTUAL END, past every
* emitted byte, anchored at LIBA_BSSEND rather than `*` (sec 21;
* learning:01M0FNC75R7YSFRNS328WHXMHN -- same idiom cat.s/ld.s
* already use). BLOBSIG only: this file's own OWNER rule (task
* #8 phase D's task text) forbids moving LFLAG..PATHBUF here --
* those stay exactly where check_purity.BIN_DEBT already counts
* them, untouched -- this is NEW state PREEXIT/CHKBLOB need, not
* a conversion of anything already emitted, so it costs no image
* bytes and no BIN_DEBT budget. Write-before-read like every
* other dum-arena cell: START (this file's very first
* instructions) writes it unconditionally, before anything --
* including the earliest possible exit path -- can read it.
*
* Ceiling guard lives HERE too, as the dum block's OWN first
* line, not after it: check_purity.py's own arena-overlay audit
* (sec 21) requires every non-dum/dend/equ/lst/end line after
* libabss.s's `put` to sit INSIDE a dum block, and `err` is not
* one of its exemptions. Placing it here costs nothing in
* meaning -- `dum LIBA_BSSEND` sets `*` to LIBA_BSSEND's own
* value (LOAD_BASE + real image length, libabss.s's own header),
* so `*` on the very next line, before BLOBSIG's own bytes, IS
* the true image end, exactly as if this were plain emitted code
* at the textual end. `err` (not `ds` -- there is no padding
* target, only an assertion) fires loudly at BUILD time if this
* file ever grows into the arena instead of silently corrupting
* the symbol table at RUN time -- same idiom as every
* `err */$BF00` ceiling elsewhere in src/bin (cat.s, echo.s,
* ...): the division is 0 while `*` fits under SYMADR, 1 once it
* does not.
*---------------------------------------------------------------
            dum   LIBA_BSSEND
            err   */SYMADR
BLOBSIG     ds    3
*-- AS_GOREAD/RDXFORM scratch. In the ARENA and not `ds`
*-- (docs/STICKY.md sec 21/28): every cell is written before it
*-- is read within one call -- RDX_FD by RDXFORM's own prologue,
*-- RDX_BOUND by its caller immediately before, RDX_LEFT from
*-- each read's transfer count -- so none is owed an emitted
*-- zero. AS_GOREAD keeps its destination in PTR0 rather than
*-- here, because the transform is (PTR0),y indexed and indirect
*-- indexing needs a zero-page pointer; PTR0 is saved and
*-- restored around the call because $E0/$E1 are the core's own
*-- STARTFL/WASORG (MACASS.S:167-168).
RDX_FD      ds    1      ;RDXFORM's fd/bound/counter -- all
RDX_BOUND   ds    1      ;  written by its caller or its own
RDX_LEFT    ds    2      ;  prologue before any read
*-- ...and the SAME ceiling again at the arena's END, which is
*-- the end that actually grows. The `err` above tests where the
*-- arena BEGINS; it stays silent while the cells below it run
*-- past SYMADR into the symbol table. That is not a cosmetic
*-- overlap: the table is written DURING assembly, so a cell
*-- landing inside it is corrupted mid-run -- an assembly that
*-- never terminates rather than an object that comes out wrong.
*-- Two lines because BLOBSIG is 3 bytes wide and the guard has
*-- to hold at both ends of it.
*--
*-- Measured margin, 2026-08-28, by bisecting BLOBSIG's width
*-- until the build flips: `ds 135` is the widest arena that
*-- still fits, `ds 136` is the first that does not -- so there
*-- are 132 bytes of headroom past today's 3. That is not much.
*-- and the GOREAD work below, now landed, spent that lot:
*-- +134 image bytes and four more arena cells put the far end
*-- PAST SYMADR, and the start-only guard assembled it silently,
*-- because the arena's START was still just under the ceiling.
*-- The symbol table then overwrote the arena mid-assembly and
*-- `as` hung in the core -- diagnosed for a whole session as a
*-- fault in the put path, which was correct throughout. This
*-- second line is what turns that into a build error; SYMADR
*-- moved to $3D00 is what bought the room. docs/AS-PUT.md's
*-- last section has the full account.
            err   */SYMADR
            dend
