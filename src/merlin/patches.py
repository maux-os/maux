"""patches.py -- the maux `as`-core patch overlay (task #8 phase B,
docs/AS-DESIGN.md section 2). NOT vendor source: this is the auditable,
named, commented diff applied on top of vendor/merlin/*.S to produce the
patched assembler core. vendor/ is NEVER modified in place (HACKING.md).

WHY A BUILD-SCRIPT OVERLAY RATHER THAN PATCHED COPIES: a copy of a 21KB
high-bit-ASCII, $8D-delimited Merlin source file is opaque to review --
nothing distinguishes "house edit" from "1985 Bredon". A table of
(file, line-span, asserted-old-text, new-text) keeps every edit named and
commented, and the staged sources are re-derived from vendor/ + this table
fresh every build, so table and artifact cannot drift apart silently.

MECHANICS. Each Merlin source file is high-bit ASCII with $8D line
terminators (confirmed: zero $0D bytes in MACASS.S; `file` reports "no
line terminators"). Line numbers are 1-based over the $8D-split list --
the same numbering docs/AS-DESIGN.md and
learning:01M0CC62FZ351EBXCAAKX52KAJ already cite (e.g. ASS.BNK1.S:1374).
Every span asserts its expected decoded text before any byte is touched;
vendor drift fails the build loudly instead of mis-patching.

STYLE: minimal-diff and label-preserving. Where a patched line carries a
label that is a branch/JSR target elsewhere (:SM, LBV, GETSYM0), the label
survives on the replacement line -- deleting it would fail assembly.
Handler bodies made unreachable (ERRWAIT's beep loop, SAV/DSK's tails)
stay in place as dead bytes rather than being deleted: smaller address
drift, smaller audit surface.

LAYOUT SAFETY (why deletions cannot break the core's own anchors): the
entry vector table is `ORG $E5F0`-pinned (MACASS.S:254), so ASMBLER=$E5F3
survives any code shrinkage; and MACASS.S:403's own ` DS $F7D0-*` pad
re-anchors PRINTENT at $F7D0 (PRINTENT.S:2 asserts it), absorbing all
AS-object drift. Bank-1 shrinkage only adds headroom to the `ERR \\$E000`
ceiling (MACASS.S:249). The one probabilistic residual is SYMPRINT.S:51's
page-boundary ERR -- if a future patch-set change trips it, add a named
1-byte DS pad here.
"""

# A Patch is (file, start_line, end_line, expected_old_lines, new_lines).
# Inclusive, 1-based, in the ORIGINAL (stock) line numbering.

P1_SYMTAB_IN_BANK = [
    # NOTE: no FENCE patch, deviating from AS-DESIGN section 2's literal
    # "SYMADR/FENCE retarget". FENCE ($C7, MACASS.S:147) is the OBJECT-
    # code write ceiling -- PRCODE compares ASMPNT (not SYMPNT) against
    # it (ASS.BNK1.S:224-229) -- so it is unrelated to the symbol table
    # and stays stock.

    # --- READ.AUX/READ.MAIN/WRITE.AUX/WRITE.MAIN brackets around
    # symbol-table access, DELETED (not retargeted): inside a maux
    # process a RAMRD/RAMWRT flip selects the KERNEL's memory, so the
    # brackets are a protection hole once SYMADR is in-bank. Out of
    # scope, verified untouched: ASS.BNK1.S:232-234 (PUTBYT object
    # writes via ASMPNT); ASSMAIN.S:782-804/825-827 (DICPNT, the REL
    # linker dictionary -- "same treatment later", AS-DESIGN sec. 2);
    # LINKER.S entirely (dormant in `as`; PUT into the core but only
    # reachable via REL paths).

    # ASSMAIN.S ASM entry: zero the symtab's first byte.
    ("ASSMAIN.S", 11, 13,
     [" STA WRITE.AUX", " STX SYMADR", " STA WRITE.MAIN"],
     [" STX SYMADR"]),

    # ASSMAIN.S REL directive: "symtab still empty?" guard.
    ("ASSMAIN.S", 647, 649,
     [" STA READ.AUX", " LDA SYMADR ;Must come before =", " STA READ.MAIN"],
     [" LDA SYMADR ;Must come before ="]),

    # ASS.BNK1.S PUTLAB: store a new label. :SM is a branch target
    # (line 442 BNE :SM) -- the label survives as a label-only line.
    ("ASS.BNK1.S", 423, 423, [" STA WRITE.AUX"], []),
    ("ASS.BNK1.S", 444, 444, [":SM STA WRITE.MAIN"], [":SM"]),

    # ASS.BNK1.S: mark a label "used" ($80 flag bit).
    ("ASS.BNK1.S", 495, 497,
     [" STA WRITE.AUX", " STA (SYMPNT),Y", " STA WRITE.MAIN"],
     [" STA (SYMPNT),Y"]),

    # ASS.BNK1.S FINDLAB0/CMPR: symbol-name compare loop.
    ("ASS.BNK1.S", 537, 539,
     [" STA READ.AUX", " LDA (SYMPNT),Y", " STA READ.MAIN"],
     [" LDA (SYMPNT),Y"]),

    # ASS.BNK1.S FINDLAB0/LBV: LBV is a branch target (BVS at :527,
    # BCC at :548) -- label moves onto the surviving LDA.
    ("ASS.BNK1.S", 550, 552,
     ["LBV STA READ.AUX", " LDA (SYMPNT),Y ;Y=0", " STA READ.MAIN"],
     ["LBV LDA (SYMPNT),Y ;Y=0"]),

    # ASS.BNK1.S PTADR: store source-line address into the entry.
    ("ASS.BNK1.S", 1090, 1094,
     [" STA WRITE.AUX", " STA (SYMPNT),Y", " INY", " STIND PL;SYMPNT",
      " STA WRITE.MAIN"],
     [" STA (SYMPNT),Y", " INY", " STIND PL;SYMPNT"]),

    # ASS.BNK1.S macro-def flag fixup: adjacent read + write brackets.
    ("ASS.BNK1.S", 1192, 1194,
     [" STA READ.AUX", " LDA (SYMPNT,X)", " STA READ.MAIN"],
     [" LDA (SYMPNT,X)"]),
    ("ASS.BNK1.S", 1197, 1199,
     [" STA WRITE.AUX", " STA (SYMPNT,X)", " STA WRITE.MAIN"],
     [" STA (SYMPNT,X)"]),

    # ASS.BNK1.S GETSYM0: THE shared symtab byte-fetch primitive (GTLEN,
    # GETLAST, NXTSYM, and everything downstream). JSR target -- label
    # survives on the LDA.
    ("ASS.BNK1.S", 1399, 1401,
     ["GETSYM0 STA READ.AUX", " LDA (SYMPNT),Y", " STA READ.MAIN"],
     ["GETSYM0 LDA (SYMPNT),Y"]),

    # SYMPRINT.S: the listing pass holds aux read-select across its WHOLE
    # alphabetize/print scan rather than bracketing per access -- TWO
    # opens (:57 for the numeric scan entry, :96 for the alpha scan
    # entry), one nested write-bracket plus the single close (:146-149).
    # Everything between runs against main unchanged.
    ("SYMPRINT.S", 57, 57, [" STA READ.AUX"], []),
    ("SYMPRINT.S", 96, 96, [" STA READ.AUX"], []),
    ("SYMPRINT.S", 146, 149,
     [" STA WRITE.AUX", " STA (SYMPNT),Y", " STA WRITE.MAIN",
      " STA READ.MAIN"],
     [" STA (SYMPNT),Y"]),
]

# P1_SYMADR_LOW / P1_SYMADR_HIGH (task #8 phase D, the `as` warm-respawn
# fix, docs/STICKY.md sec 31's cure applied to `as`): SYMADR's OWN value
# split out of P1_SYMTAB_IN_BANK into its own one-line group, because two
# DIFFERENT process-core artifacts now need two DIFFERENT values at the
# SAME MACASS.S:187 span, and apply_patches() cannot apply two patches to
# one line in the same build. Everything else P1 does (the bracket
# deletions above) is IDENTICAL for both -- only this one equate differs.
#
# P1_SYMADR_LOW = $2000, byte-for-byte the original P1 text, used by both
# `hardware` (check-ascore's own verification artifact) and `process`
# (`ld`'s embedded core -- LINKER reuses SYMADR as its dictionary base,
# docs/STICKY.md sec 31's "free ride", so this value may NOT move without
# breaking `ld`, which is why `ld`'s own variant keeps it).
#
# P1_SYMADR_HIGH is the NEW `warm` variant's value: the symbol table
# lives entirely ABOVE `as.s`'s own image end instead of inside it. `as`
# cannot keep SYMADR in-image at all: MACASS.S's ASM entry (its own
# DUMMY $800 macro-state block) zeros as.s's LOAD_BASE entry head on
# EVERY run (src/bin/as.s's own file-header "EXCLUSION ZONE" comment),
# so `as`'s bank is NEVER retained warm by the kernel's lazy-free guard
# (docs/kernel/lazyfree.s's LZ_RETAIN, an 8-byte head compare) -- cold-
# loading 16KB on every spawn in the edit-assemble-link-run hot path.
# Fixing THAT (src/bin/as.s's own RESTHEAD) only helps if the SYMBOL
# TABLE also survives a warm respawn without corrupting the next run's
# copy of the core blobs -- and an in-image SYMADR (the `ld`-style
# LINKWIN shape) cannot: `as`'s own GTLEN walks the table until it finds
# a zero byte, so the arena must be pre-zeroed across its WHOLE extent,
# and that extent (~9-10KB) is either too small (hangs on real blob
# bytes) or as large as the blobs it would have to sit inside (grows the
# image by that much) -- see src/bin/as.s's own file-header for the
# full argument. Moving SYMADR above the image end sidesteps both: the
# zeroed arena touches no image byte, ever, so nothing a warm respawn
# inherits can corrupt it.
#
# $3D00 chosen page-aligned (ASS.BNK1.S:526's `LDY #SYMADR ;=0` needs
# low byte 0, same constraint P1_SYMADR_LOW's own comment already
# established) -- NOT simply above the raw image end. Measured wrong
# once (src/bin/as.s's own build): $3800 cleared the image with room to
# spare but landed inside src/liba/libabss.s's own bss arena, which
# every program that `put`s liba carries PAST the image end at zero
# disk cost but real process-memory cost (docs/STICKY.md sec 21's `dum`
# idiom) -- LIBA_BSSEND is $39B5 in this build, not the raw image end.
# ($3D00 -> $4000 2026-08-28: liba's SIO_STAGE grew 512 -> 1024 for
# the stage-owner buffering and the as.s guards fired; symbol window
# is 8,192B now. The paragraph below is the $3D00-era measurement.)
# $3D00 clears LIBA_BSSEND plus `as.s`'s own tiny arena (BLOBSIG and
# AS_GOREAD's RDX_* scratch; see that file's SYMADR equate for the
# arithmetic and the bug this caught) by a measured 250 bytes, and
# still leaves a bigger symbol arena (SYMADR..SRC_BASE-1, 8,960B) than
# the old effective ~9,095B -- no: 8,960 is 135 bytes SMALLER than
# that, which is the price of the move and is stated rather than
# rounded away. It remains far larger than the $2000-in-image layout
# it replaced. Was $3C00 until 2026-08-28, when the AS_GOREAD work
# grew as.s past it (docs/AS-PUT.md).
#
# TWO `err */SYMADR` guards in as.s catch it if this stops holding --
# one at the arena's start and one at its END, because for a while
# there was only the first and it does not see the arena grow.
P1_SYMADR_LOW = [
    ("MACASS.S", 187, 187,
     ["SYMADR = $1000 ;Aux mem"],
     ["SYMADR = $2000 ;maux P1: main-bank symtab (was aux $1000)"]),
]

P1_SYMADR_HIGH = [
    ("MACASS.S", 187, 187,
     ["SYMADR = $1000 ;Aux mem"],
     ["SYMADR = $4000 ;maux P1w: symtab above image (was aux $1000)"]),
]

P4_POLL_NEUTER = [
    # KEYCHK (ASS.BNK1.S:1374): the pagination-pause / ^C poll, called
    # from the listing tail (:1129), SYMPRINT.S:33's KEY?, and
    # PRINTENT.S:25. Forcing A=0 makes `CMP #$85 / BLT RT1` return
    # immediately -- "no key" unconditionally, callers see A=0.
    ("ASS.BNK1.S", 1374, 1374,
     ["KEYCHK LDA KEY"],
     ["KEYCHK LDA #0 ;maux P4: no key ever -- never poll HW"]),

    # WAIT (ASS.BNK1.S:1384-1385): the blocking `LDA KEY / BPL WAIT`
    # spin (reached via INFWAT's JSR WAIT -- KEYCHK's old fallthrough is
    # gone with the patch above). Deleting the branch-back leaves
    # `WAIT LDA KEY` falling into RT1's RTS: one non-blocking read.
    ("ASS.BNK1.S", 1385, 1385, [" BPL WAIT"], []),

    # ERRWAIT (MACASS.S:324): the assembly-error beep/keywait (falls
    # into INFWAT, the disk-swap wait, when entered minus). Jumping
    # straight to RT (-> PRNTLIN) skips beep, keywait, and INFWAT --
    # INFWAT has no other caller (grepped), so this neuters it too.
    # The dead loop body stays in place: BYTE-NEUTRAL by construction
    # (BMI 2 + LDA# 2 -> JMP 3 + NOP 1). SIZE DISCIPLINE, learned the
    # hard way (two broken builds, 2026-08-19): the stock AS section
    # ends EXACTLY flush against its `ERR \$F7D0` ceiling AND carries
    # page-boundary ERR assertions that a net size change upstream can
    # push onto a boundary -- so P4 and P5 are each net-ZERO in the AS
    # section, and only P1 (whose deletions are the point) moves
    # layout at all.
    ("MACASS.S", 324, 325,
     ["ERRWAIT BMI INFWAT", " LDA #$40 ;Called by assembly error"],
     ["ERRWAIT JMP RT ;maux P4: no beep-wait -- always proceed",
      " NOP ;maux P4: size-neutral filler, body below is dead"]),

    # Known residual, deliberately NOT patched: ASSMAIN.S:91's
    # `LDA KEY` at START reads $C000 once per source line for the ^C
    # abort / ^D list-toggle checks. It cannot block (no loop) and never
    # clears the strobe except on ^D; flagged for the phase-C front end
    # as a real-hardware touch, not a park risk.
]

P5_EXIT_REDIRECT = [
    # The sole `JMP EDITOR` in the core chain (SYMPRINT.S OUT -- the
    # only exit path; GETLINE.S's DONE/QUIT falls through into it).
    # MACED.S's own JMP EDITOR is editor-internal, not core. The
    # exit path's `BIT STROBE` is deleted with it: clearing the
    # keyboard strobe on the way out is a real-hardware touch a maux
    # process must not make (P4's own rationale), and its 3 bytes pay
    # exactly for ASEXIT below -- keeping P5 net-zero in the AS
    # section (see P4's size-discipline note).
    ("SYMPRINT.S", 18, 20,
     [" BIT STROBE", " BIT CONTROL", " JMP EDITOR"],
     [" BIT CONTROL",
      " JMP ASEXIT ;maux P5: MACED absent under maux"]),

    # ASEXIT: a self-loop landing pad INSIDE the core, placed in the
    # dead space MACASS.S:403's own `DS $F7D0-*` pad already reserves --
    # so PRINTENT stays anchored at $F7D0 and the $F879 ceiling is
    # untouched. Phase C's front end pokes its real exit JMP over these
    # 3 bytes at load time (process LC RAM is plain writable, AS-DESIGN
    # sec. 3); phase B proves control LANDS here via until_pc, exactly
    # how check-asmspike proved ASMBLER. Address is discovered from the
    # built ASMOBJ/AS object by self-jump scan, not hardcoded. Credit:
    # in-core landing pad shape from the parallel phase-B recon.
    ("MACASS.S", 403, 403,
     [" DS $F7D0-*"],
     ["ASEXIT JMP ASEXIT ;maux P5: exit pad, see check-ascore",
      " DS $F7D0-*"]),
]

P7_DSK_SAV_NEUTER = [
    # Both handlers reduced to their common continuation (JMP RESTART =
    # "directive done, next line" -- SAVOK?'s own pass-1 early-out uses
    # the same target via JRS). Bodies stay as dead bytes; DIRFLG is
    # never set so DODSK's per-byte MLI streaming stays dormant until
    # the phase-C front end arms it itself (AS-DESIGN P7/P8).
    ("ASSMAIN.S", 686, 686,
     ["SAV JSR SAVOK?"],
     ["SAV JMP RESTART ;maux P7: front end owns the file"]),
    ("ASSMAIN.S", 704, 704,
     ["DSK JSR SAVOK?"],
     ["DSK JMP RESTART ;maux P7: front end owns the file"]),
]

# DROPPED 2026-08-20 (task #8 phase C, docs/AS-DESIGN.md section 14 --
# "Re-test P9 with the process core"). NOT in GROUPS/HARDWARE_GROUPS/
# PROCESS_GROUPS below; kept defined (unreferenced) for the archival
# record and in case a future patch-set change resurrects the ORIGINAL
# hang for an unrelated reason. Section 11's own state-diff programme
# root-caused the real bugs the hang was standing in for -- FPHI,
# SENDMSG's calling convention, two more un-stubbed $E0xx entries, the
# SYMADR zero invariant, and (this pass) bug 4 (PUTBYT's RAMWRT, fixed
# by the P10 class removal) and a zero-page collision between this
# file's own liba PTR1/PTR2 and the core's OBJPNT/OBLEN (WRITEOBJ) --
# and once ALL of those are fixed, the ORIGINAL ISLOC/FINDLAB0 hang does
# not recur: `check-as` (both GOODMOD.S and the multi-label/forward-ref/
# `:LOCAL` src/test/asmultitest.s -- the exact module P9's own comment
# below cites as its residual-risk stress test) passes BYTE-IDENTICAL
# with a process core built `--exclude P9`. Section 9's own warning
# ("P9 must not ship as a bare NOP with an uncharacterised root
# trigger") is satisfied by removal, not by further characterization --
# the retry loop this patch neutered is simply never reached once the
# real bugs are fixed, so there is nothing left for it to mask.
P9_LABEL_RETRY_NEUTER = [
    # ASS.BNK1.S ISLOC (SETLAB's non-local-label path, entered whenever
    # SETLAB's caller finds PASNUM nonzero -- ASSMAIN.S's own opcode-vs-
    # macro-name disambiguation temporarily fakes PASNUM around a
    # `JSR FINDLAB` probe): `:AGAIN JSR FINDLAB0 / CLV / TYA / TAX /
    # BEQ :AGAIN` retries FINDLAB0 while it reports "not found" (Y=0).
    # LIVE-TRACED 2026-08-20 (task #8 phase C's `make check-as` hang):
    # FINDLAB0's global-search branch (BVS LBV not taken -- OVERIDE's
    # bit is legitimately clear here) UNCONDITIONALLY resets SYMPNT to
    # SYMADR and rescans WORKSP/OFFSET, NEITHER of which the loop body
    # ever changes -- so every retry is bit-for-bit identical to the
    # last. Confirmed empirically: SYMPNT reset to $2000, OFFSET=X=0,
    # A/Y=0 at every one of hundreds of sampled iterations across a
    # ~1B-cycle capture (cycle-accurate trace_capture dump), and the
    # loop makes zero softswitch touches for the same span (rules out a
    # KEYCHK-family poll -- P4 already neutered those). Once genuinely
    # "not found" on attempt 1, it stays "not found" forever: the retry
    # can only ever complete via an external event (a keystroke, a
    # MACED-driven re-entry) a maux process cannot receive. Neutering
    # the back-branch makes the loop body run exactly once and fall
    # through to the SAME success-path cleanup (`INC PASNUM / DEC
    # MACLEV / SETLS ... / RTS`) the original loop uses on its own exit
    # -- behavior-preserving for the only reachable case (repeating a
    # deterministic search changes nothing) and byte-neutral (2-byte
    # branch -> 2 NOPs, matching P4/P5's size discipline). Verified: `as`
    # assembling a label-then-immediate-operand module (src/test/
    # asmodtest.s -- previously ~980M-cycle hang) now reaches ASEXIT with
    # a byte-identical object; check-ascore's own PACKOP2.S never visits
    # this branch (no label shares a line with, or precedes in-module, a
    # `#`-immediate the way asmodtest.s does), so P1/P4/P5/P7's teeth are
    # unaffected. See docs/AS-DESIGN.md section 8/9 for the full writeup
    # and the deposited learning handle.
    #
    # RESOLVED 2026-08-20 (docs/AS-DESIGN.md section 10): P1 is NOT the
    # cause. Decisive experiment -- asmodtest.s assembled through (a) the
    # STOCK, unpatched core (real aux symtab, MACED resident) and (b) THIS
    # SAME P1+P4+P5+P7 core with P9 EXCLUDED, both driven the standard way
    # (MACED's own `L`/`ASM` command, check-ascore's own harness) -- both
    # complete cleanly, 0 errors, correct object. The main-bank symtab
    # (P1's whole point) is therefore innocent: FINDLAB0 finds the label
    # fine when the core is entered normally. The hang reproduces ONLY
    # when the identical P9-excluded core is driven via `as.s`'s own
    # direct `JMP $E5F3` maux-process entry (confirmed by re-embedding
    # that exact core into as.bin and rerunning check_as.py: same
    # done=$00/timeout signature as the original report). So the retry's
    # non-termination is a property of the headless/as.s entry context,
    # not of where the symbol table lives -- P1 is exonerated, not merely
    # unproven guilty.
    #
    # Why the single pass is CORRECT for what P9 actually neuters: ISLOC
    # is SETLAB's bookkeeping path for a plain (non-local, non-macro)
    # label already recorded by pass 1 -- its job here is to update
    # SYMPNT/LASTSYM/PASNUM/MACLEV, not to hand a resolved VALUE to the
    # current line's code generation (object bytes for a line come from
    # the separate CHKOPND/EVLOPND/FINDLAB operand path, never from this
    # branch). So neutering the retry cannot corrupt the CURRENT line's
    # emitted bytes; the only residual risk was to SUBSEQUENT local-label
    # bookkeeping that reads LASTSYM/SYMPNT afterward. That residual is
    # exactly what src/test/asmultitest.s (multiple labels, a forward
    # reference, and a Merlin `:LOCAL` label) is for: assembled through
    # this exact core (P9 included) via check-ascore's own harness, it is
    # BYTE-IDENTICAL to merlin32's object (23/23 bytes) -- forward refs
    # and local-label scoping both resolve correctly with P9 landed.
    #
    # P9 stays landed (does not mask a resolution bug); the genuine,
    # not-yet-fully-characterized bug is in as.s's own entry contract or
    # the maux process-scheduling context, tracked as an open item in
    # docs/AS-DESIGN.md section 10, separate from this patch set.
    ("ASS.BNK1.S", 380, 380,
     [" BEQ :AGAIN"],
     [" NOP ;maux P9: no retry -- one search attempt only, see below",
      " NOP ;maux P9: size-neutral filler, same 2-byte span"]),
]

# P10, first attempt (2026-08-20), TRIED AND REVERTED -- kept as a short
# record, superseded by P10_BANK_AGNOSTIC_CORE below. Root cause: ASS.
# BNK1.S's PUTBYT (232-234) brackets each OBJECT byte write with
# WRITE.AUX (RAMWRT on) / the write / WRITE.MAIN (RAMWRT off) -- correct
# on real hardware (RAMWRT defaults off/main, matching P1's own
# unbracketed symtab writes and check-ascore's "(c) main $2000+ has
# symtab activity"), but inside a maux process (kernel baseline RAMWRT
# ON/aux) it strands every LATER unbracketed write in the kernel's
# shared main memory once PUTBYT's trailing WRITE.MAIN fires -- live-
# verified via aux $2000 stuck at its original "not done" byte forever
# (docs/AS-DESIGN.md section 12). The first fix attempt neutered ONLY
# PUTBYT's `STA WRITE.MAIN`, leaving `STA WRITE.AUX` in place -- an
# UNBALANCED half-removal (the pair HACKING.md's task text warns about).
# It fixed `as` but BROKE check-ascore ("(a) control never reached
# ASEXIT"), because the one shared core artifact then had a RAMWRT
# baseline neither consumer's own default agreed with. See
# docs/AS-DESIGN.md section 13's ruling: the two consumers need two
# artifacts, not one core patched to split the difference.

# P10_BANK_AGNOSTIC_CORE (RULED 2026-08-20, docs/AS-DESIGN.md section 13):
# the class-wide fix. P1's title was "symtab-in-bank" but its own bracket
# deletions are members of a broader class -- "the embedded chain never
# touches RAMRD/RAMWRT at all" -- and P1's own comment flagged exactly
# two site-groups as "out of scope, verified untouched": ASS.BNK1.S's
# PUTBYT (232-234, bug 4's exact site) and ASSMAIN.S's DICPNT/REL
# dictionary code (782-804, 825-827). This group is those two, patched
# the SAME way P1 patched everything else: brackets DELETED, not
# retargeted, balanced pair by balanced pair (never landing an unmatched
# half -- see the reverted first attempt above). It does NOT re-merge
# P1's own patches into this file: doing that would change what
# EXCLUDING "P1" reverts, and check-ascore's own P1 tooth ("(c) symtab
# back in aux") depends on P1's current, narrower content. Per
# docs/AS-DESIGN.md's task text ("fold them in or supersede, whichever
# is cleaner, and say which"): chosen answer is SUPERSEDE, in
# documentation only -- P1's bracket deletions are declared, here, to be
# members of this same class; P10 is the class's remainder. The UNION
# (P1 + P10) is what actually leaves zero RAMRD/RAMWRT touches in the
# embedded chain -- verified by re-running the same decode-and-grep sweep
# used to build docs/AS-P10-ENUMERATION.txt against a P1+P10 derivation.
# A bank-agnostic core is correct on real hardware too (nothing needs to
# MOVE, only to stop moving) -- but it is validated as the PROCESS core
# only (this group is never in the HARDWARE core's set; see GROUPS/
# HARDWARE_GROUPS/PROCESS_GROUPS below), because a process's kernel-set
# RAMWRT baseline (stuck aux) and stock Merlin's own default (stuck
# main, until something flips it) are opposite defaults -- a bank-
# agnostic core is only behavior-preserving for the default it actually
# runs under.
#
# EXTENDED 2026-08-20 (docs/LD-DESIGN.md section 4's ruling): the "two
# site-groups" above turned out to be three. LINKER.S -- PUT into the
# SAME bank-1 object as ASS.BNK1.S (MACASS.S:237-241) -- carries its own
# 9 switch instructions in 5 brackets, entirely un-swept by either P1 or
# the original two-site-group P10, because docs/AS-P10-ENUMERATION.txt's
# scope statement wrongly asserted "as.s does not embed LINKER.S" rather
# than reading it out of the PUT chain. This group's own "UNION (P1 +
# P10) is what actually leaves zero RAMRD/RAMWRT touches in the embedded
# chain" claim, one paragraph up, was therefore false until this
# extension landed -- see the LINKER.S entries below for the sites and
# docs/AS-P10-ENUMERATION.txt for the re-derived, re-verified totals.

# SIZE DISCIPLINE (found the hard way, 2026-08-20, see docs/AS-DESIGN.md
# section 14): a first pass at this group used PLAIN deletion, P1's own
# style. It applied cleanly (every asserted span matched) and check-
# ascore-process's (d) divergence audit passed -- but the real-Merlin
# REBUILD then failed with a garbled, unrelated-looking error ("Bad SAV
# in line: 411", inside MACASS.S's own build tail, nowhere near any P10
# site) that took a targeted bisection to explain: ASS.BNK1.S:1510 carries
# `ERR BIN!SYMBOL&$FF00`, a PAGE-ALIGNMENT assertion on two of ROUTBL's
# routine addresses (a repeated-idiom risk this file's own header already
# names for SYMPRINT.S:51, "if a future patch-set change trips it, add a
# named 1-byte DS pad"). P1's OWN deletions already shrink ASS.BNK1.S
# substantially and that assertion still holds under P1 alone (check-
# ascore, hardware, is green) -- but P10's ADDITIONAL, un-padded shrink
# was just enough to cross the boundary P1 alone did not. The established
# house fix for exactly this risk (P4/P5/P9's own comments: "BYTE-NEUTRAL
# by construction", "matching P4/P5's size discipline") is NOP padding,
# not smaller deletions -- so every P10 site below pads to the ORIGINAL
# instruction's exact object-code length (STA/LDA absolute to $C002-
# $C005 is 3 bytes -- those addresses are all > $FF, never zero-page;
# STA (zp,X)/LDA (zp),Y is 2 bytes), leaving ASS.BNK1.S/ASSMAIN.S's
# layout from each patched point onward BYTE-IDENTICAL to what P1 alone
# already produces. Re-verified after this fix: check-ascore-process's
# rebuild reaches SAVE/MERLIN bound with 0 errors (docs/AS-DESIGN.md
# section 14).
P10_BANK_AGNOSTIC_CORE = [
    # ASS.BNK1.S PUTBYT: the OBJECT-byte write. :PUTBYT is a branch
    # target (ASS.BNK1.S:229 `BLT :PUTBYT`) -- label survives on the
    # surviving store, same idiom as P1's :SM/LBV/GETSYM0 patches. No
    # switch at all: a maux process's kernel baseline is ALREADY
    # RAMWRT-on-aux (docs/AS-DESIGN.md section 13), so the object byte
    # lands correctly with nothing to bracket. Original span = STA abs
    # (3B) + STA (zp,X) (2B, kept) + STA abs (3B) = 8B; replacement =
    # STA (zp,X) (2B) + 6 NOPs = 8B, net zero.
    ("ASS.BNK1.S", 232, 234,
     [":PUTBYT STA WRITE.AUX", " STA (ASMPNT,X)", " STA WRITE.MAIN"],
     [":PUTBYT STA (ASMPNT,X)",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span"]),

    # ASSMAIN.S ADDREL/DICPNT: the REL-module external-symbol-dictionary
    # writer, gated by `BIT RELFLAG` (set only by a source's own `REL`
    # directive) -- reachable the moment any `as`-assembled module
    # declares itself relocatable, independent of whether the (un-
    # embedded) LINKER ever runs, since ASSMAIN.S's own REL-directive
    # bookkeeping is what reaches this code. Left alone it reopens bug
    # 4's exact hole for the first REL module `as` assembles. DICPNT's
    # own ADDRESS is untouched (same "out of scope" treatment P1 gave
    # FENCE -- REL/`ld` tree-conversion is out of v1's scope per
    # AS-DESIGN section 0/6, and this patch only removes switches, not
    # relocates pointers). Two independent pairs: an outer WRITE.AUX
    # (782) / WRITE.MAIN (804) dictionary-entry write spanning a
    # conditional (`BPL :STDP` at 792) that skips a NESTED READ.AUX
    # (794) / READ.MAIN (801) external-symbol read; none of the four
    # lines carries a label. Each STA/LDA absolute is 3 bytes -> 3 NOPs.
    ("ASSMAIN.S", 782, 782, [" STA WRITE.AUX"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("ASSMAIN.S", 794, 794, [" STA READ.AUX"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("ASSMAIN.S", 801, 801, [" STA READ.MAIN"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("ASSMAIN.S", 804, 804, [" STA WRITE.MAIN"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),

    # ASSMAIN.S ADDREL's per-byte dictionary SEND loop (NXDE, feeds
    # PRCODE for the REL object stream) -- same repeating-bracket shape
    # as PUTBYT. ]LOOP is the loop's own branch target (ASSMAIN.S:830
    # `INC DICPNT / BNE ]LOOP`) -- label survives. Same 8B/2B/6-NOP
    # shape as PUTBYT above.
    ("ASSMAIN.S", 825, 827,
     ["]LOOP STA READ.AUX", " LDA (DICPNT),Y ;Send dict", " STA READ.MAIN"],
     ["]LOOP LDA (DICPNT),Y ;Send dict",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span"]),

    # LINKER.S (task #8, docs/LD-DESIGN.md section 4 -- "the unswept
    # sites, a live correction to P10"). MACASS.S:237-241 is `ORG $D000
    # / PUT LINKER / PUT ASS.BNK1`, both landing in the SAME bank-1
    # object (`SAV ASMOBJ/PROASM.BANK1`, MACASS.S:251) as.s copies to
    # $D000 -- LINKER.S IS embedded. docs/AS-P10-ENUMERATION.txt's
    # original "as.s does not embed it" scope statement was wrong (its
    # own correction banner). LINKER is dormant -- nothing in `as`
    # reaches LINK yet -- so this group closes a DOCUMENTED hole, not an
    # observed bug: no behavioural gate exercises it (none can; `ld`/a
    # future check-ld is the first thing that will).
    #
    # 9 switch instructions in 5 brackets, confirmed against
    # vendor/merlin/LINKER.S by decode_lines() (NOT taken on faith from
    # the correction banner's own line list):
    #   1. ADD's dictionary-address write (90, WRITE.AUX open) and
    #      PUTDIC's EXT-dict-entry write (151, WRITE.AUX open) share ONE
    #      physical close: BUMPDIC's own leading `STA WRITE.MAIN` (325),
    #      reached by `JSR BUMPDIC` from both callers (104, 157/158) --
    #      BUMPDIC only advances DICPNT and returns, so deleting its own
    #      WRITE.MAIN closes whichever opening called it. Same two-
    #      opens/one-close shape as P1's own SYMPRINT.S pattern (57/96
    #      -> 149), as three independent single-line spans here since
    #      the two opens are not textually adjacent to the shared close.
    #      BUMPDIC and PUTDIC are each JSR/branch targets elsewhere
    #      (grepped) -- labels survive on the leading NOP, same idiom as
    #      :PUTBYT/:SM/LBV/GETSYM0/]LOOP above.
    #   2. LOADEE (177/179): WRITE.AUX / `STA (DICPNT),Y` / WRITE.MAIN --
    #      adjacent bracket, identical 3B/2B/3B=8B shape to PUTBYT
    #      above. LOADEE is a BEQ target (138) -- label moves onto the
    #      surviving store; its ";Y=0 here" comment (documents the
    #      register state the surviving indexed store depends on) moves
    #      with it.
    #   3. GETPL's :SAUX (320/322): READ.AUX / `LDA (PL),Y` / READ.MAIN
    #      -- same 8B shape. :SAUX is a BNE target (315) -- label
    #      survives. GETPL itself is called from ~10 sites past LOADEE
    #      (dictionary-fix routines, all unreachable today since LINK is
    #      never called) -- removing the switches here does not change
    #      GETPL's own PL/dictionary bookkeeping, only which bank the
    #      byte comes from.
    #   4. FIXEXT's end-of-dictionary marker (390/395): WRITE.AUX / two
    #      unrelated `STA (DICPNT),Y` + DICPNT-bump instructions
    #      (untouched -- no label, no branch lands inside) / WRITE.MAIN
    #      -- two independent single-line spans, deliberately not
    #      combined into one span the way case 2's is (the middle is not
    #      a single 2-byte instruction to preserve).
    # PL ($55, MACASS.S:104) and DICPNT ($82, MACASS.S:121) are both
    # zero page, confirming the 2-byte `(zp),Y`-indexed loads/stores kept
    # mid-bracket; WRITE/READ ($C004/$C002, MAIN=0/AUX=1, MACASS.S:220-
    # 223) are all > $FF, confirming every switch touch is `STA`
    # absolute, 3B, NOP-padded per this group's own size discipline
    # above -- LINKER.S precedes ASS.BNK1.S in the SAME $D000 PUT chain
    # under the SAME `ERR \$E000` ceiling (MACASS.S:237-249), so an
    # un-padded shrink here risks the identical page-boundary trip this
    # file's own note already found once in ASS.BNK1.S/ASSMAIN.S. Every
    # span here re-verified byte-for-byte against real merlin32 (a
    # standalone before/after assembly of exactly this instruction set),
    # not just counted by addressing-mode rule.
    #
    # Residual, deliberately left alone (minimal-diff style, this file's
    # own STYLE header): LINKER.S:104's own comment, `JSR BUMPDIC ;Turns
    # on WRITE.MAIN`, now describes removed behavior (BUMPDIC's own
    # WRITE.MAIN is gone) -- a cosmetic staleness outside the 9 sites
    # this group is chartered to sweep, not a switch touch itself.
    ("LINKER.S", 90, 90, [" STA WRITE.AUX"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("LINKER.S", 151, 151, ["PUTDIC STA WRITE.AUX"],
     ["PUTDIC NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("LINKER.S", 177, 179,
     ["LOADEE STA WRITE.AUX ;Y=0 here", " STA (DICPNT),Y",
      " STA WRITE.MAIN"],
     ["LOADEE STA (DICPNT),Y ;Y=0 here",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span"]),
    ("LINKER.S", 320, 322,
     [":SAUX STA READ.AUX", " LDA (PL),Y", " STA READ.MAIN"],
     [":SAUX LDA (PL),Y",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span",
      " NOP ;maux P10: size-neutral filler, same 8-byte span"]),
    ("LINKER.S", 325, 325, ["BUMPDIC STA WRITE.MAIN"],
     ["BUMPDIC NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("LINKER.S", 390, 390, [" STA WRITE.AUX"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
    ("LINKER.S", 395, 395, [" STA WRITE.MAIN"],
     [" NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span",
      " NOP ;maux P10: size-neutral filler, same 3-byte span"]),
]

# P11_OBJPNT_A000 (task #8, docs/AS-DESIGN.md section 15/16): first-light
# measured the source window at only 24576B ($2000-$7FFF) -- shared with
# the symbol table -- because OBJPNT's hardcoded $8000 (ASSMAIN.S:22-24)
# is BOTH the object base AND (via PUTLAB's unsigned high-water-vs-OBJPNT
# compare, ASS.BNK1.S:450-452 -- the same fact P1's own SYMADR=$2000
# choice already depends on) the symbol table's overflow ceiling. Moving
# OBJPNT to $A000 grows that shared window to 32768B ($2000-$9FFF) and
# still leaves $A000-$BEFF (~7.9K) for one module's object -- FENCE
# ($C000, the OBJECT-code WRITE ceiling PRCODE checks ASMPNT against,
# ASS.BNK1.S:224-229) is untouched, same "out of scope" reasoning P1
# already gave it: FENCE bounds the write pointer, not OBJPNT.
#
# THE ASL TRICK DOES NOT COMPOSE FOR $A000 -- checked, not assumed.
# ASSMAIN.S:20-24 today is:
#   POKE FENCE+1;$C0   expands to LDA #$C0 / STA FENCE+1 (sets FENCE
#                      hi byte, untouched by this patch)
#   STA DICPNT+1       reuses the SAME leftover A=$C0
#   STX OBJPNT         X=0 here (from the entry's init loop) -- OBJPNT
#                      lo byte, unaffected by this patch
#   ASL      ;$80      A: $C0 -> $80 (carry out discarded) -- OBJPNT=
#                      $8000 is an ACCIDENT of FENCE's own value: ASL
#                      of FENCE's high byte happens to land on OBJPNT's
#                      intended high byte because $C0<<1(mod 256)=$80.
#   STA OBJPNT+1
# ASL(A) can only double A mod 256, and we do not want to change FENCE
# (still $C000, still correct) to manufacture a different leftover A.
# No 1-byte accumulator op reaches $A0 from $C0 either (ASL->$80,
# ROR/LSR->$60, checked exhaustively) -- so this is a DIRECT immediate
# load, not a reused-register trick, and it costs 1 byte more than the
# ASL it replaces (ASL A implied = 1B; LDA #imm = 2B). This growth is
# SAFE, not merely tolerated: ASSMAIN.S is PUT into the AS chain (PUT
# ASSMAIN, MACASS.S:265) between `ORG $E5F0` and MACASS.S:403's own
# `DS $F7D0-*` pad, which re-anchors PRINTENT at a FIXED address
# regardless of upstream size drift in that same chain (this file's own
# "LAYOUT SAFETY" header) -- verified empirically against the real-
# Merlin rebuild (check-ascore-process's own (d)/rebuild phases): no
# page-boundary ERR (SYMPRINT.S:51, the one probabilistic residual this
# file's header names) trips from the extra byte, and MACASS reports the
# SAME total size as before the patch.
#
# Every other OBJPNT reference in vendor/merlin/ (grepped: ASS.BNK1.S
# PUTLAB/PUTBYT, ASSMAIN.S's memory-full arithmetic, LINKER.S, MACEXEC.S)
# reads/writes OBJPNT symbolically -- none hardcodes $80/$8000 -- so this
# one site is the whole of the change.
# P15_REL_DICT_INBANK (S9 REL route, docs/S9-PLAN.md section 6 L0):
# the assembler's REL dictionary accumulates DOWNWARD from DICPNT
# (MAKDIC: SBC #4) and ADDREL sends it -- then the ENT/EXT symbol
# list and both terminators -- through PRCODE, the ordinary emission
# path, so under `as` (DSK neutered, P7) the finished memory object
# already ends [code][fixups][00][symbols][00], the exact on-disk
# REL layout (learning:01M0HAG4X2079QQNVBKR5F4R77). P10 already
# neutralized every aux flip on this path (MAKDIC's WRITE.AUX/
# READ.AUX pairs, NXDE's send bracket), so the dictionary builds
# IN-BANK today. What stock still gets wrong for maux is WHERE:
#
#   1. DICPNT init reuses FENCE's leftover A=$C0 (ASSMAIN.S:20-21),
#      so the first pre-decremented 4-byte entry lands at $BFFC --
#      inside the process bank's $BF00 page, which
#      mm.procbnk2.equ reserves as the "reserved-but-optional
#      MLI overlay page" (also PRC_BRK_LIM, the highest legal
#      break). An explicit LDA #$BF starts the dictionary below it.
#      +2 bytes, absorbed by MACASS.S:403's `DS $F7D0-*` re-anchor
#      pad, the same argument P11 already proved for its +1.
#
#      TOOTH RUN 2026-08-29, recorded honestly: excluding P15
#      leaves check-as GREEN. The scribble self-heals for object
#      BYTES -- entries written at $BFFC-down are read back from
#      the same addresses, and without the init moved the stock
#      $C0 terminator test still matches -- so what P15 protects
#      is the RESERVED PAGE ITSELF, not the output. `as` makes no
#      MLI-overlay use of $BFxx today, so nothing currently breaks
#      without it; the day that page becomes load-bearing for a
#      process's own syscalls, an unpatched REL assembly corrupts
#      it silently mid-run. Named trigger, per the accepted-gaps
#      rule: whoever considers dropping P15 must first check
#      whether BF00_OVERLAY is still optional.
#   2. NXDE's all-sent test is `EOR #$C0` (ASSMAIN.S:823) -- with
#      the init moved it must be $BF, or the send loop sweeps the
#      overlay page's 256 bytes into the object. Byte-neutral; the
#      BEQ path's "A must = 0" contract survives ($BF EOR $BF).
#
# The stock OOMEM guard (CMP SYMEND, ASSMAIN.S:772-775) modeled the
# shared-aux layout and is inert under P1 (symtab at $4000 main);
# the real collision -- dict bottom vs object top -- is enforced by
# as.s's front end post-ASEXIT, not by this patch (a zp compare
# retarget is not byte-neutral; see S9-PLAN section 6 L0).
#
# WARM_GROUPS ONLY: this is `as`'s own core. ld's PROCESS core must
# not change ("LINKER's DICPNT free ride", the WARM_GROUPS header
# below), and the hardware core is real Merlin verbatim on this
# path, where aux $BFFC IS the right address.
# P16_REL_CLOSE_MEMORY (S9 REL route, docs/S9-PLAN.md section 6 L0):
# ADDREL -- the routine that appends the REL dictionary, symbol list
# and terminators to the object via PRCODE -- has exactly ONE caller:
# CLOSE (GETLINE.S QUIT jsr's it at every assembly's end; found the
# hard way after two files' worth of "only one caller" -- the DSK
# handler's own JSR at ASSMAIN.S:710 is the mid-pass pathname-swap
# case, not the end-of-assembly one). Stock CLOSE bails on clear
# DIRFLG before reaching ADDREL, because stock refuses to keep a REL
# object in memory at all ("save is allowed only if DSK active").
# Under `as` DIRFLG is clear forever (P7), so a REL assembly came out
# as bare code: no dictionary, CODELEN never parked, aux 0 --
# measured 2026-08-29 on the first REL run (68B against real
# Merlin's 92B reference).
#
# The fix is a pure REORDER, byte-for-byte the same five
# instructions: hoist JSR ADDREL + JSR LENOBJ above the DIRFLG
# guard. Both are self-gating -- ADDREL exits on a plus RELFLAG
# (ABS assemblies unchanged, byte-identity gates prove it), LENOBJ
# just recomputes OBLEN = ASMPNT-OBJPNT (MACASS.S:371, no other
# effect), which after ADDREL's sends makes OBLEN cover code +
# dictionary, exactly what WRITEOBJ needs to put the whole REL
# image on disk. NOCLS's backward BPL moves 6 bytes further --
# still a short hop. WARM_GROUPS only, same scoping as P15.
P16_REL_CLOSE_MEMORY = [
    ("ASSMAIN.S", 585, 589,
     ["CLOSE BIT DIRFLG",
      " BPL NOCLS ;Exit if no DSK file",
      " JSR ADDREL ;Do rel stuff if active",
      " JSR LENOBJ",
      " JSR SWAP ;Recall file name"],
     ["CLOSE JSR ADDREL ;maux P16: dict for memory objects",
      " JSR LENOBJ ;maux P16: OBLEN covers code+dict",
      " BIT DIRFLG",
      " BPL NOCLS ;Exit if no DSK file",
      " JSR SWAP ;Recall file name"]),
]

P15_REL_DICT_INBANK = [
    ("ASSMAIN.S", 21, 21,
     [" STA DICPNT+1"],
     [" LDA #$BF ;maux P15: dict under the $BF00 page",
      " STA DICPNT+1"]),
    ("ASSMAIN.S", 823, 823,
     [" EOR #$C0 ;Table all sent?"],
     [" EOR #$BF ;maux P15: matches DICPNT init"]),
]

P11_OBJPNT_A000 = [
    ("ASSMAIN.S", 22, 24,
     [" STX OBJPNT", " ASL ;$80", " STA OBJPNT+1"],
     [" STX OBJPNT",
      " LDA #$A0 ;maux P11: OBJPNT hi byte, was $80",
      " STA OBJPNT+1"]),
]

# P12_LD_EXIT_PADS (task #8, docs/LD-DESIGN.md section 1/7a's ruling):
# `ld` cannot infer link status from "control reached a resident vector"
# alone -- LINK collapses THREE completion shapes (success/constraint-
# error/fatal) onto TWO targets, HIT ($E02A) and JERROR. The ruling is
# the P5 technique applied twice: turn each `JMP HIT`/`JMP JERROR` INTO
# its own landing pad (a self-referencing `JMP <here>`, the exact
# ASEXIT shape) so the front end can locate it (by self-jump scan, same
# discipline as FINDEXIT -- an address is a fact about a specific build,
# never hardcoded) and poke its own handler over it at load time. Unlike
# ASEXIT this needs no dead-space relocation: `JMP HIT`/`JMP JERROR` are
# each already exactly 3 bytes (JMP absolute), and `JMP LD_EXITn` at the
# SAME location is also exactly 3 bytes -- byte-neutral by construction,
# no NOP padding needed, no risk to ASS.BNK1.S's page-alignment ERR
# (this group never changes any instruction's length).
#
# LD_EXIT1 covers BOTH `JMP HIT` sites (LINKED's success exit, line 380,
# and ERRMEM's constraint-error exit, line 240) -- per LD-A2, ORGFLG
# (seeded nonzero by the front end, cleared only by LINKED) is what
# distinguishes those two cases once both land on the SAME pad, so one
# shared pad is correct, not a loss of information. LD_EXIT2 covers
# FILERR's `JMP JERROR` (line 344) alone -- a genuinely different,
# fatal-error completion, kept on its own vector so the front end does
# not need to inspect anything beyond "which pad fired" to know a link
# was fatal.
#
# CORRECTION TO docs/LD-DESIGN.md's LD-A4 table, found empirically while
# building this group (verified against the REAL compiled object, not
# re-derived from source alone -- `grep`-for-bytes in
# build/ascore-process-bank1.obj, the exact artifact `ld.s` embeds):
# JCLOSE/JRLOAD/JERROR/ENTRY are NOT `INT+offset` against INT=$E000 as
# LD-A4 assumed by analogy with WRMVEC/SENDMSG/WARMDIS (which ARE
# literal $E0xx constants, confirmed correct). LINKER.S's OWN `JERROR =
# INT+$15` (line 29) resolves against MACASS.S:49's `INT = $B200`
# (also copied verbatim in MACEXEC.S:89) -- the ONLY `INT =` definition
# either file supplies, and it is IN SCOPE when LINKER.S is PUT (MACASS.
# S:237-241, well after line 49). Direct byte search of the built
# object confirms this, not merely the arithmetic: `JSR $B20C`
# (JCLOSE), `JSR $B218` (JRLOAD), `JMP $B215` (JERROR, tail-jumped, one
# occurrence only -- LINKER.S:344, so THIS group's LD_EXIT2 patch is the
# only place that needs updating, no separate $B215 stub required), and
# `JSR $B240` (ENTRY, 8 call sites) all found at the expected offsets;
# `JSR $E00C`/`$E015`/`$E018`/`$E040` do NOT occur anywhere in the
# object. AUXMOVE ($C311) and SENDMSG ($E033) ARE literal, unaffected --
# confirmed present at their documented addresses. This does not change
# THIS group (HIT/JERROR are redirected by source patch, not by
# installing a stub at their numeric address, so LD_EXIT2's own landing
# address is whatever LINKER.S:344's patched bytes assemble to, found by
# scan, never $B215 itself) -- it changes where `ld.s` installs the
# JCLOSE/JRLOAD/ENTRY stubs (see that file's own STUB_* equates) and is
# recorded here, at the patch site the finding was made building, per
# HACKING.md's dialect/mechanism-divergence deposit rule.
#
# In BOTH HARDWARE_GROUPS and PROCESS_GROUPS, same reasoning as P11:
# byte-neutral and dormant for both (check-ascore's own PACKOP2.S never
# reaches LINK either), so keeping the two cores identical here avoids
# a THIRD hardware/process divergence that neither existing gate can
# exercise, for a cost of zero (no size, no behavior change on any path
# either gate drives).
P12_LD_EXIT_PADS = [
    ("LINKER.S", 240, 240,
     [" JMP HIT"],
     ["LD_EXIT1 JMP LD_EXIT1 ;maux P12: ld exit pad 1, see patches.py"]),
    ("LINKER.S", 344, 344,
     [" JMP JERROR"],
     ["LD_EXIT2 JMP LD_EXIT2 ;maux P12: ld exit pad 2, see patches.py"]),
    ("LINKER.S", 380, 380,
     [" JMP HIT"],
     [" JMP LD_EXIT1 ;maux P12: ld exit pad 1, see line 240"]),
]

# P13_LD_NO80COL_PROBE (task #8, found LIVE running `ld` for the first
# time -- the P4 class of bug, one more instance of it). LINKED's own
# tail (LINKER.S:351-354) does `LDA $F800 / CMP #$20 / BNE :LINKED /
# JSR PRINTENT` -- a REAL-HARDWARE 80-column-firmware detection probe
# (an installed 80-col card's firmware happens to start with a $20=JSR
# opcode at that ROM address; stock Merlin uses this to decide whether
# to print a fancier resolved-externals listing). Inside a maux process
# $F800 is NOT hardware ROM -- it is ordinary process RAM, squarely
# inside CORE_AS's own compiled span ($E5F0-$F879, this file's own
# "LAYOUT SAFETY" header / as.s's own layout comment) -- so the probe
# reads WHATEVER BYTE the assembled core happens to have at that offset
# instead of a real hardware signature. Verified NOT a hypothetical:
# `python3 -c "print(open('build/ascore-process-as.obj','rb').read()
# [0xF800-0xE5F0])"` -- the byte AT that exact offset in the shipped
# core is $20, a pure coincidence of whatever routine's own opcode
# happens to land there, and it makes the probe MATCH every time. The
# false match calls PRINTENT (a real, working routine -- it happily
# executes) whose own listing code clobbers FROM/ENDMOVE/DEST ($3C/
# $3E/$42, LINKER.S:33-35) -- the SAME three zero-page cells LINKED's
# immediately-following AUXMOVE setup depends on -- so by the time
# `JSR AUXMOVE` runs, DEST no longer points at SYMADR ($2000) and the
# final image gets copied from/to garbage addresses. Live-diagnosed:
# a real link (RTMAIN+RTLIB) produced a 72-byte output (OBJPNT/OBLEN
# both read back CORRECTLY as $2000/72 by the front end) whose ACTUAL
# CONTENT was `ld`'s own process argv text, not the linked image --
# proving the corruption is in WHERE AUXMOVE copies from/to, not in
# the front end's own capture.
#
# Same shape and same fix as P4 (KEYCHK/WAIT/ERRWAIT): a maux process
# must never probe real hardware state that isn't there. Neutered by
# turning the whole 10-byte span (LDA abs 3B + CMP# 2B + BNE 2B + JSR
# abs 3B) into 10 NOPs -- unconditional fall-through to :LINKED,
# PRINTENT never called, byte-neutral by construction (this file's own
# size-discipline lesson, P10/P11's own sections). LINKED is a real
# JSR/branch target elsewhere (FIXEXT's own `BEQ LINKED`) -- the label
# survives on the first NOP, same idiom as :PUTBYT/:SM/LBV/GETSYM0.
# Same BOTH-groups reasoning as P12: dormant for hardware (check-ascore
# never reaches LINK), so keeping the two cores identical costs nothing.
P13_LD_NO80COL_PROBE = [
    ("LINKER.S", 351, 354,
     ["LINKED LDA $F800", " CMP #$20", " BNE :LINKED", " JSR PRINTENT"],
     ["LINKED NOP ;maux P13: no 80-col probe, see patches.py",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span",
      " NOP ;maux P13: size-neutral filler, same 10-byte span"]),
]

# P14_AUXMOVE_RELOCATE (task #8, found LIVE -- LD-RECON section 4's own
# flagged-but-unresolved open question, now resolved the hard way: "does
# $C000-$CFFF I/O space bypass RamWorks bank selection the way it
# bypasses LC banking? ... NOT verified in this pass". It doesn't --
# verified live: `ld.s` poked `JMP LD_AUXMOVE` over $C311 (AUXMOVE's
# real address, LINKER.S:36) at startup exactly like its SENDMSG/
# WARMDIS/JCLOSE/JRLOAD/ENTRY stubs, and a peek of $C311 immediately
# before `JSR AUXMOVE` fires read back `00 00 00` -- the poke's own STA
# instructions silently no-op there. $C000-$CFFF is real Apple II slot-
# ROM/I/O address space (unlike $D000-$FFFF, the language-card range a
# maux process privately owns as writable RAM, where the other five
# stubs above all correctly land) -- there is no RAM behind it for an
# ordinary process to write through a plain STA. Confirmed NOT a
# generic "can maux processes write $C000-Cfff at all" question either:
# this is specifically about AUXMOVE's own address landing outside the
# writable range, not a broader I/O-space claim.
#
# Fix: relocate the EQUATE, not the instruction. `AUXMOVE = $C311` is
# LINKER.S's own symbolic constant (line 36) -- every `JSR AUXMOVE`
# reference (one call site, LINKER.S:371) resolves against it, so
# repointing the equate to a free byte in the SAME $B200 page the
# JCLOSE/JRLOAD/ENTRY stubs already prove writable (LD-A4, this file's
# own P12/ld.s header) moves the call target with a ONE-LINE change --
# no dead-space scan, no self-jump pad needed (unlike the P12 exit
# pads, this is a JSR/RTS call-and-return site, and `ld.s`'s own poked
# `JMP LD_AUXMOVE` preserves that: the JSR's return address stays on
# the stack untouched by the redirect, and LD_AUXMOVE's own trailing
# RTS pops it exactly like SENDMSG_IMPL already does for its inline-
# string redirect). $B260 sits comfortably clear of JCLOSE ($B20C),
# JRLOAD ($B218), ENTRY ($B240, 3-byte JMP ends $B242), and PARMADR
# ($B250, 2 bytes, unused) -- verified against LD-A4's own table plus
# this file's own P12-header address list, no overlap.
#
# PROCESS-ONLY (unlike P12/P13, which are dormant-either-way and live
# in both groups): on REAL hardware $C311 is the genuine, working 80-
# column-firmware AUXMOVE entry -- relocating the equate would be
# actively WRONG there (nothing real lives at $B260), not merely
# untested. check-ascore never exercises LINK regardless, so this
# costs nothing today, but it is not the same "harmless either way"
# shape as P12/P13 and should not be asserted as such.
P14_AUXMOVE_RELOCATE = [
    ("LINKER.S", 36, 36,
     ["AUXMOVE = $C311"],
     ["AUXMOVE = $B260 ;maux P14: was $C311, see patches.py"]),
]

# P9 excluded (DROPPED 2026-08-20, see P9_LABEL_RETRY_NEUTER's own
# comment above -- not a typo).
GROUPS = {
    "P1": P1_SYMTAB_IN_BANK,
    "P1_SYMADR_LOW": P1_SYMADR_LOW,
    "P1_SYMADR_HIGH": P1_SYMADR_HIGH,
    "P4": P4_POLL_NEUTER,
    "P5": P5_EXIT_REDIRECT,
    "P7": P7_DSK_SAV_NEUTER,
    "P10": P10_BANK_AGNOSTIC_CORE,
    "P11": P11_OBJPNT_A000,
    "P12": P12_LD_EXIT_PADS,
    "P13": P13_LD_NO80COL_PROBE,
    "P14": P14_AUXMOVE_RELOCATE,
    "P15": P15_REL_DICT_INBANK,
    "P16": P16_REL_CLOSE_MEMORY,
}

# THREE artifacts from one overlay (docs/AS-DESIGN.md section 13, ruling
# 2; extended task #8 phase D, docs/STICKY.md sec 31's cure applied to
# `as`). HARDWARE_GROUPS is today's check-ascore set (P9 dropped
# 2026-08-20 -- it was already inert here per teeth_ascore.py's own
# note: PACKOP2.S never exercises the retry loop P9 neutered), so that
# gate keeps its meaning and its 6/6 teeth. PROCESS_GROUPS adds P10 --
# the bank-agnostic class -- for the core `ld.s` embeds (byte-for-byte
# UNCHANGED by this pass -- `ld`'s own SYMADR=$2000 free ride,
# docs/STICKY.md sec 31, must not move). P11 (OBJPNT $A000, docs/
# AS-DESIGN.md section 15/16) is in ALL THREE sets: the hardware core is
# a verification artifact, not a shipped one, so keeping the cores'
# object base identical means check-ascore actually EXERCISES P11 (via
# its own (b)/(c) assertions, retargeted to $A000) rather than leaving it
# covered only by check-as. All three are asserted subsets of GROUPS at
# import time so a renamed/typo'd group fails loudly instead of silently
# building an incomplete core.
#
# WARM_GROUPS is `as.s`'s OWN core (task #8 phase D): identical to
# PROCESS_GROUPS in every respect EXCEPT SYMADR's value -- P1_SYMADR_HIGH
# instead of P1_SYMADR_LOW, moving the symbol table above `as`'s own
# image end so a warm respawn's un-recopied blobs can never overlap it
# (see P1_SYMADR_HIGH's own header and src/bin/as.s's file header for
# the full argument). `ld` keeps embedding PROCESS_GROUPS -- it must
# NOT switch to this set, or LINKER's DICPNT free ride breaks.
HARDWARE_GROUPS = frozenset(
    {"P1", "P1_SYMADR_LOW", "P4", "P5", "P7", "P11", "P12", "P13"})
PROCESS_GROUPS = HARDWARE_GROUPS | {"P10", "P14"}
WARM_GROUPS = (PROCESS_GROUPS - {"P1_SYMADR_LOW"}) \
    | {"P1_SYMADR_HIGH", "P15", "P16"}
assert HARDWARE_GROUPS <= set(GROUPS) and PROCESS_GROUPS <= set(GROUPS)
assert WARM_GROUPS <= set(GROUPS)
assert PROCESS_GROUPS - HARDWARE_GROUPS == {"P10", "P14"}
assert WARM_GROUPS - HARDWARE_GROUPS \
    == {"P10", "P14", "P1_SYMADR_HIGH", "P15", "P16"} \
    and HARDWARE_GROUPS - WARM_GROUPS == {"P1_SYMADR_LOW"}
VARIANT_GROUPS = {"hardware": HARDWARE_GROUPS, "process": PROCESS_GROUPS,
                  "warm": WARM_GROUPS}


def build_all_patches(exclude=()):
    """{file: [patch, ...]} from the named groups, minus `exclude` --
    the teeth mechanism (build with one group reverted, watch its gate
    assertion fail). See scripts/build_ascore_image.py --exclude."""
    all_patches = []
    for name, plist in GROUPS.items():
        if name not in exclude:
            all_patches.extend(plist)
    by_file = {}
    for p in all_patches:
        by_file.setdefault(p[0], []).append(p)
    return by_file


def exclude_for_variant(variant, user_exclude=()):
    """The `exclude` set build_all_patches()/derive() need to build ONE
    of the two named variants ('hardware' or 'process'), with `--exclude`
    teeth on top. Groups outside the variant's own set are excluded
    unconditionally (e.g. hardware always excludes P10); user_exclude
    (teeth) is unioned in on top of that, never subtracted from it."""
    variant_groups = VARIANT_GROUPS[variant]
    return (set(GROUPS) - variant_groups) | set(user_exclude)


ALL_PATCHES = build_all_patches()

# P2 (config) is data, not a source patch: VALIDATE.PO ships no PARMS at
# all (no PARMS.S anywhere in vendor/merlin/ -- the "Update source?"
# prompt on that disk comes from MACED's built-in default). This is the
# 44-byte PARMS blob from the real Merlin-8 v2.58 disk, embedded so the
# build has no external-file dependency, with the two load-bearing bytes
# asserted -- not patched -- because the shipped blob already carries the
# safe values (verified empirically 2026-08-19 by dumping the v2.58
# disk's /MERLIN.8/PARMS: offset 4 = $83, offset 13 = $00):
#   offset  4: SLOT/80-col flag $83 -- NEVER $C3 ($C3 sets the V-bit that
#              moves ProDOS into aux, which maux owns; docs/SELFHOST.md)
#   offset 13: SEARCHR 0 -- "Update source (Y/N)?" suppressed
# The $E000 in-memory template (MACED.S:38-57) has a DIFFERENT byte
# layout than this on-disk blob; these offsets are from the blob dump,
# not derived from the template.
PARMS_BYTES = bytes([
    0x3C, 0x00, 0x50, 0x80, 0x83, 0x01, 0x09, 0x00,
    0xAA, 0x01, 0x09, 0xDE, 0x04, 0x00, 0x0E, 0x14,
    0x1F, 0x04, 0x05, 0x00, 0x00, 0x48, 0xEC, 0xA4,
    0xC6, 0xB1, 0xA4, 0xC6, 0xB2, 0xA4, 0xC6, 0xB3,
    0xA4, 0xC6, 0xB4, 0xA4, 0xC6, 0xB5, 0xA4, 0xC6,
    0xB6, 0xA4, 0xC6, 0xB7,
])
PARMS_SLOT_OFFSET = 4
PARMS_SLOT_VALUE = 0x83
PARMS_SEARCHR_OFFSET = 13
PARMS_SEARCHR_VALUE = 0x00
assert PARMS_BYTES[PARMS_SLOT_OFFSET] == PARMS_SLOT_VALUE
assert PARMS_BYTES[PARMS_SEARCHR_OFFSET] == PARMS_SEARCHR_VALUE


def decode_lines(raw):
    """Split $8D-delimited high-bit source into (decoded_texts,
    raw_segments). Re-encoding must reuse raw_segments for unpatched
    lines: some lines mix low-ASCII $20 spaces into high-bit text, and a
    blind re-encode rewrites them (build_merlin_src_image.py's lesson).
    """
    raw_segments = raw.split(b"\x8d")
    line_texts = [bytes(b & 0x7F for b in seg).decode("ascii", "replace")
                  for seg in raw_segments]
    return line_texts, raw_segments


def encode_line(text):
    """Encode a freshly-authored (house) line to high-bit ASCII."""
    return bytes((ord(ch) | 0x80) for ch in text)


def apply_patches(raw, patches, filename):
    """Apply (file, start, end, old_lines, new_lines) spans to one
    file's raw bytes. Asserts every span's expected text against the
    actual decoded content first -- a mismatch means vendor/ diverged
    from what this table was written against, and the build fails
    loudly. Returns (patched_bytes, applied_count)."""
    line_texts, raw_segments = decode_lines(raw)
    out_segments = []
    i = 0
    spans = sorted((p for p in patches if p[0] == filename),
                   key=lambda p: p[1])
    for a, b in zip(spans, spans[1:]):
        if a[2] >= b[1]:
            raise ValueError(f"overlapping patch spans in {filename}: "
                             f"{a[1]}-{a[2]} and {b[1]}-{b[2]}")
    applied = 0
    for (_, start, end, old_lines, new_lines) in spans:
        s0, e0 = start - 1, end - 1
        while i < s0:
            out_segments.append(raw_segments[i])
            i += 1
        actual = line_texts[s0:e0 + 1]
        if actual != old_lines:
            raise ValueError(
                f"{filename}:{start}-{end} does not match the patch's "
                f"expected old text -- vendor/merlin/ has diverged.\n"
                f"  expected: {old_lines!r}\n  actual:   {actual!r}")
        for text in new_lines:
            out_segments.append(encode_line(text))
        i = e0 + 1
        applied += 1
    while i < len(raw_segments):
        out_segments.append(raw_segments[i])
        i += 1
    return b"\x8d".join(out_segments), applied
