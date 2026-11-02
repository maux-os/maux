#!/usr/bin/env python3
"""`sh`'s WARM-RESPAWN gate (`make check-shwarm`, docs/STICKY.md sec 32).

Companion to scripts/build_shwarm_image.py (the image and the scripts --
read its header for how a second `sh` is arranged) and to
scripts/textaudit.py, whose observer this reuses.

THE HOLE THIS CLOSES. sec 29 audited all 33 programs against lazy free
and gave `sh` the verdict DIRTY-TAIL: it writes its own image, its
entry head does not move, so the kernel RETAINS its bank and the next
`sh` runs on mutated text. Every other DIRTY-TAIL program was cleared
by a REPEAT PAIR. `sh` had none -- nothing in the tree spawned `sh`
twice in one boot -- so the fleet's largest warm claim was the one
nobody could test, on the program that will `fork()` first.

WHAT IT ASSERTS, in the order a red run should be read:

  0. VACUITY FIRST. Exactly three `sh` exits (two nested, one outer);
     the two nested ones in the SAME bank -- a pid IS its bank, so
     that is what makes "the bank we poisoned" and "the bank run 2
     reused" one bank; run 2 observed WARM at its own exit, from the
     kernel's LZ_WARM; the poison read back out of that bank; the
     harness reporting $AA; and run 1's output carrying every marker
     in build_shwarm_image.MARKERS, so a boot where every command was
     "not found" cannot pass with two identical near-empty files.
  1. THE REPEAT PAIR. /mnt/MAUX/SH1 and /mnt/MAUX/SH2 byte-identical. Run 1
     is the expectation, so this needs no golden data and cannot rot.
  2. EVERY MOVED IMAGE BYTE IS CLASSIFIED. The bytes of `sh`'s image
     that changed are resolved against sh's own merlin32 -v1 symbol
     dump and must all fall inside SCRATCH_CELLS or REPL_ZERO_CELLS
     below. A new moved cell is a new unproven claim and says so.

  3. THE STAMP FOLLOWS BOTH COPIES (KFIX3 review B2). A first boot of
     the same image watches the ONE instruction that stores SEGSTAMP
     (shsegi.s) and reads X at each cold start: SEG_INIT leaves the
     end page of the segment it just copied in X, so X must be the
     SECOND segment's end page at every stamp. The first cut stamped
     after the first copy -- a sh killed before the $D000 copy then
     left a stamped bank, and the next warm spawn skipped the copy and
     ran a half-installed segment. Static half: the stamp must be
     stored by exactly one instruction in the whole image.

THE POISON, both halves (learning:01M0M9R7RT22JEPP2R0Y6J9MBX, sec 26).
A gate that does not poison proves nothing about uninitialised reads,
because a freshly spawned bank may already be zero and zero is exactly
the value a read-before-write bug needs to look correct:

  * THE ARENA (LIBA_ZPG..SH_ARENA_END, `dum`, uncleared): filled with $A5
    in every candidate child bank before the machine is stepped, and
    filled AGAIN -- in the bank run 1 actually used -- at the instant
    run 1 dies, so run 2 inherits $A5 rather than run 1's leftovers.
    This is where CMD_ARGC, FDABUF and CHILDMAP live today: sec 29
    named them as `sh`'s moved IMAGE bytes, and sec 28's ds->dum sweep
    moved them out of the image into exactly this window.
  * THE SURVIVING IMAGE CELLS (SCRATCH_CELLS below): `sh`'s remaining
    emitted scratch, poisoned by NAME at the same instant. The arena
    poison cannot reach them -- they are text -- and run 1's leftovers
    are a weaker test than $A5 because run 1 ran the same script and
    tends to leave exactly the value run 2 would have written. Each
    cell's write-before-read claim is stated beside it; the poison is
    what makes the claim falsifiable.

BOTH POISONS ARE ADDRESSED FROM merlin32's OWN SYMBOL DUMP, never
hardcoded: LIBA_ZPG is the load address plus the image length, so it
moves whenever sh's code size does, and every cell below is placed by
the assembler's PC.

WHY THE STOP IS ON LZ_RETAIN AND NOT A POLL. It is the kernel's own
retire path, entered once per process exit with A = the dying bank,
BEFORE the kernel decides whether to keep the bank and before anything
else can touch it -- so the poison lands strictly between run 1's
death and run 2's spawn, and cannot race a SYS_SPAWN the way a
step-and-poll driver can. textaudit.TextAuditor.in_kernel() rejects
the userland stops at the same 16-bit address
(learning:01M0MYC6NPJDYT62Q5D1M0SRKX).

WHAT THIS GATE FOUND, deposited as learning:01M0NWAK2AQSH42GGGKTRJ2F2Y:
`sh`'s warm respawn was BROKEN. Run 2 read `$?` before running
anything and got run 1's last exit status, and read `$V` before
assigning and got run 1's value -- LASTSTATUS and VARNAMES are two of
the seven cells sec 28 kept as REAL EMITTED ZEROS because a REPL reads
them on its first pass, and an emitted zero is a property of the
LOADER, which lazy free stopped running. src/bin/sh.s establishes them
itself now (SH_INIT_ZR).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from textaudit import SYMS, TextAuditor, boot, load_syms, R_DONE  # noqa: E402
import build_shwarm_image as bs  # noqa: E402
import arena  # noqa: E402 -- private-tree listings

sys.path.insert(0, os.path.expanduser(os.environ.get('A2TIL', '~/src/a2til')))
import a2til  # noqa: E402
import vpath  # noqa: E402,F401  (docs/VROOT.md: virtual paths for a2til)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
DISK = os.path.join(BUILD, 'shwarm.po')
SYMFILE = os.path.join(BUILD, 'MAUXSH.SYSTEM_Output.txt')
SYSBIN = os.path.join(BUILD, 'MAUXSH.SYSTEM')
VOL = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
SH_PATH = f'/{VOL}/BIN/SH'.upper()

POISON = 0xA5
LOAD_BASE_SH = 0x0800                 # inc/mm.procbank.equ
# Labels the manifest's wound-back `org`s leave at FILE addresses inside
# the segments' low copy, where TRAPTAB and CSFORWORDS now live. They
# name no cell, so they must not end a cell's span.
TAIL_MARKERS = ('SH_SEG_LOW', 'SH_SEG2_SRC', 'SH_FILE_END',
                'SH_FILE_ENDP1')
# Banks a spawned child can land in on this image. Poisoned wholesale
# rather than predicted, and asserted afterwards against the bank the
# runs actually used (check_ls.py's own vacuity guard).
CAND_BANKS = range(2, 12)
# scripts/teeth_shdead.py P1 builds sh with a loop that fills the whole
# dead copy with $A5 right after SEG_INIT; the bytes that loop moves are
# the proof's own doing, not a finding, so that run (and only that run)
# sets this and the dead copy is classified.
DEAD_POISONED = os.environ.get('SHDEAD_POISONED') == '1'
PFX_MAX = 8                           # sh.s PFX_MAX

# The harness's progress cells (src/test/shtestb.s, aux bank 1).
R_DONE = 0x1290
R_ERR = 0x1291
R_STEP = 0x1292

# ---------------------------------------------------------------------
# SCRATCH_CELLS -- the emitted cells inside `sh`'s image that a run
# writes, with the reason each is safe to inherit. This is the
# per-cell half of the verdict; the $A5 poke is what tests it.
#
# `sh`'s arena cells (CMD_ARGC, FDABUF, CHILDMAP, the pipe arrays, the
# glob and command tables) are NOT here: sec 28 moved them past the
# image end, where the arena poison covers them instead.
# ---------------------------------------------------------------------
SCRATCH_CELLS = {
    # CAP_LINE_MARK re-zeroes all three bytes at the top of every call
    # -- and MUST, because LSEEK(SEEK_CUR) reads them as the DELTA and
    # overwrites them with the absolute mark, so a stale value would be
    # ADDED to the next line's offset. MAINLOOP calls it before every
    # READLINE, so no reader can see a value this run did not write.
    'LINE_MARK': 3,
    # Written on BOTH branches of CAP_LINE_MARK (1 on success, stz on
    # failure) before RW_LOOP_PUSH or CR_STARTSCAN can read it.
    'LMARK_OK': 1,
    # CR_FIND's first instruction is `sta CRWANT`; its only reader is
    # the compare four instructions later.
    'CRWANT': 1,
    # Set to 1 by MAINLOOP before the first segment of every line and
    # stz'd after each segment; CR_STARTSCAN is the only reader.
    'SEG_FIRST': 1,
    # BUILD_PATH's PATHTAB cursor: `sty SH_NEXTI` before the read that
    # consumes it, once per candidate.
    'SH_NEXTI': 1,
    # READLINE writes LINELEN for every line before STRIPCOMMENT or
    # TOKENIZE reads it; TOKENIZE opens with `stz NTOK` / `stz TOKI`
    # and TOKTMP is its own within-line scratch.
    'LINELEN': 1,
    'NTOK': 1,
    'TOKTMP': 2,
    'TOKI': 1,
    # TOKWY: TOKENIZE's own token-start stash, `stx TOKWY`
    # unconditionally at :tokstart's classify step -- BOTH entry
    # paths now (2026-09-15, quote concatenation, docs/SH-FEATURES
    # .md sec 23) -- before any of its several readers (:bpop's
    # `cpx TOKWY`, :qbare's own group/heredoc lookahead, :segterm's
    # write-cursor stash) ever runs. First appears in the moved list
    # this pass: a token that starts quoted and concatenates into
    # bare content now reaches :bpop with a FRESH TOKWY where it
    # used to see whatever the previous token left there -- the
    # write itself is not new, only that its VALUE now actually
    # varies run to run.
    'TOKWY': 1,
    # QFLAGVAL/QCH: TOKENIZE's per-quoted-SEGMENT state, both stored
    # by :qsetup (shtok.s) from the opening quote character it just
    # matched, immediately before it enters :doquoted -- which is the
    # only reader of either, and cannot be entered any other way.
    # First appear in the moved list 2026-09-16, and for a reason
    # worth stating rather than waving through: the sub-script had no
    # quoted word in it until the segment row went in
    # (`TRAP 'ECHO TRAPPED' INT`, docs/SH-SUBSET.md ruling 7.6), so
    # these two cells had never been WRITTEN by this gate's script at
    # all. Nothing about them changed; the coverage did.
    'QFLAGVAL': 1,
    'QCH': 1,
    # ZR_CMD_TABLES `stz NCMD` before every segment's PARSE.
    'NCMD': 1,
    # MLI parmlist ref_num/trans_count fields, which must stay
    # CONTIGUOUS with their parmlists and so could not move to the
    # arena (learning:01M0M9R7RT22JEPP2R0Y6J9MBX). Every one of them is
    # either written BY the syscall that fills it and read only after
    # that call returned carry-clear, or stored from a live fd
    # immediately before the call that consumes it:
    #   SH_OPARM_REF   OPEN_REDIR_RD/WR/AP: `bcs :fail` guards the read
    #   SH_CPARM_REF   CLOSE_FD_A's own first instruction
    #   SH_TOPARM_REF  PATH_EXISTS: read only after a clean SC_OPEN
    #   SH_TCPARM_REF  copied from SH_TOPARM_REF two lines later
    #   SH_GOPARM_REF  glob's opendir, same `bcs` guard
    #   SH_GRPARM_REF  stored from SH_GOPARM_REF before the SC_READ
    #   SH_GRPARM_TRN  written by that SC_READ, read after it
    #   SH_GCPARM_REF  stored from the live dir fd before SC_CLOSE
    'SH_OPARM_REF': 1,
    'SH_CPARM_REF': 1,
    'SH_TOPARM_REF': 1,
    'SH_TCPARM_REF': 1,
    'SH_GOPARM_REF': 1,
    'SH_GRPARM_REF': 1,
    'SH_GRPARM_TRN': 2,
    'SH_GCPARM_REF': 1,
    # The `echo` builtin's two cells: ECHOFD is stored on BOTH branches
    # of the redirect probe before :emit reads it, and ECHOI is set to
    # 1 before the argument loop -- the bare-`ECHO` path that skips the
    # loop never reads it at all.
    'ECHOI': 1,
    'ECHOFD': 1,
    # Word expansion (DOEXPAND/EMITB/EXP_FINISH). EXPX is stored at
    # DOEXPAND's entry; EXPBUF is a bump buffer written at EXPX and
    # read back only up to the NUL EXP_FINISH lays down itself,
    # including at the clamp boundary; DXSAVE is written immediately
    # before its own :restore.
    'EXPX': 1,
    'EXPBUF': 128,        # EXPBUFLEN
    'DXSAVE': 2,
    # EMITVAR's variable-name scratch: `stz VNLEN` at entry, VNBUF
    # filled 0..VNLEN-1 before :scandone reads it, VNRESUMEY `sty`
    # before the matching `ldy`.
    'VNBUF': 16,          # VARNAMELEN+1
    'VNLEN': 1,
    'VNRESUMEY': 1,
    # BUILD_PATH's PATHTAB prefix cursor: `stz SH_PATHI` at entry.
    'SH_PATHI': 1,
    # -- CELLS THAT MEASURE CLEAN AND ARE STILL CLAIMS ---------------
    # sec 29's own caveat: "a store of the value a cell was loaded with
    # measures CLEAN". These five never appear in the moved list --
    # they are cleared before every use and, on a script with no errors
    # and no here-docs, cleared to the zero they already held. The
    # runtime diff can therefore say nothing about them, and under lazy
    # free "it was zero" is a property of the LOADER, not of the
    # program. The poison is the only thing that tests them:
    #   PARSE_ERR / CURARGC / HD_ACTIVE / DUPN   ZR_CMD_TABLES, before
    #                                            every segment's PARSE
    #   TOK_ERR                                  TOKENIZE's own entry
    # KFIX3 item 0: the two biggest tables live INSIDE the segments'
    # low copy (sh.s, "TRAPTAB and CSFORWORDS"), so they are image
    # bytes to this gate, not arena. Both are written before read:
    # a trap slot is read only for an armed signal (TRAPACT, zeroed
    # at every entry; the slot is stored by `trap` first), and a
    # `for` row only after FOR_NEXT filled it. The poison between
    # the two runs is what tests that, and on a warm respawn the
    # bytes under them (the copy's source) are dead by design.
    'TRAPTAB': 4096,
    'CSFORWORDS': 2048,
    # SH-PREFIX Phase 0: the arena's write-before-read buffers moved
    # into the same dead copy (sh.s, the block after CSFORWORDS). Each
    # was already poisoned as arena by this gate; now they are image
    # bytes, so they are named here instead. Sizes are the `ds`
    # operands (check_spans fails a stale one).
    'GLOBBUF': 1984,         # MAXGLOB*GLOBREC, GLOB_KEEP before GLOBN
    'LINEBUF': 256,
    'TOKPTR': 256,           # TOKENIZE, below the count it publishes
    'HD_BODY': 255,
    'HDLINEBUF': 256,
    'RAWLINE': 256,
    'EXPBUF': 128,
    'OPBUF': 256,
    'RDBUF': 256,
    'RL_BUF': 256,
    'SH_PATHSRC': 96,
    # SH-SEQ C: the `.` continuation's two line buffers, in the same
    # dead copy. TOKOFF is written per token by TOKENIZE before
    # DOT_SAVE reads TOKOFF[TOKI]; PRETOK is filled from LINEBUF just
    # ahead of TOKENIZE every line.
    'TOKOFF': 128,           # MAXTOK
    'PRETOK': 256,
    # SH-ROOM: the alias table moved into the same dead copy. NOT write-
    # before-read as a block: START's ALI_INIT clears each slot's first
    # name byte and ALI_END (never ALI_VALS) and every reader goes
    # through an occupied name byte -- read-after-publication (docs/
    # SH-ROOM-NOTES.md sec 4). The poison makes that falsifiable: a
    # slot ALI_INIT forgot lists $A5 garbage in run 2.
    'ALI_NAMES': 128,
    'ALI_VALS': 256,
    'ALI_END': 8,
    # SH-ROOM2: the editor's history ring, the dead copy just below the
    # alias table (it was LC data). Read-after-publication again: ED_INIT
    # clears ED_HN/ED_HUSED, ED_HADD writes an entry before it publishes
    # it, and every reader asks ED_HN first. A script never touches it
    # (RL_ED is 0 off the console), so here the poison proves a script
    # run does not READ it; check-shedit's hist case proves the other
    # direction (a console shell recalls only what it added itself).
    'ED_HRING': 512,
    'PARSE_ERR': 1,
    'CURARGC': 1,
    'HD_ACTIVE': 1,
    'DUPN': 1,
    'TOK_ERR': 1,
    # sh's ENTRY stores, for the same reason: START sets all three
    # explicitly, so poisoning them tests START rather than the loader.
    'CUR_IN_FD': 1,
    'SRC_DEPTH': 1,
    'SH_XTRACE': 1,
}

# ---------------------------------------------------------------------
# REPL_ZERO_CELLS -- the other class, and the one this gate was
# written for. sec 28 kept these as REAL EMITTED ZEROS because `sh` is
# the tree's only REPL and reads them on its FIRST pass, before
# anything has run to set them. Under a copying loader the image
# supplied that zero on every spawn. Under lazy free it does not: the
# image is not recopied, so whatever run 1 left in them is what run 2
# starts with.
#
# They are NOT poisoned. Poisoning would test a claim nobody makes --
# these cells do not claim to be written before read, they claim to
# ARRIVE ZERO. The honest test is the sub-script, which reads each one
# before writing it and then leaves it dirty for the next run
# (build_shwarm_image.SUB), and the repeat pair is what reports the
# answer.
# ---------------------------------------------------------------------
REPL_ZERO_CELLS = {
    'VARNAMES': 128,     # a free slot IS a zero name byte
    'VARVALS': 256,      # paired with VARNAMES
    'VAREXP': 8,         # ENV_STAGE walks it regardless of occupancy
    'LASTSTATUS': 1,     # `$?` before any command has run
    'CSPTR': 1,          # construct-stack depth: only inc/dec
    'POS_SHIFT': 1,      # `$1`/`$#` before any `shift`
    'SCAN_ACT': 1,       # CR_STARTSCAN, before any scan
    'PCR_PEND': 1,       # CR_INSTALL reads it above its own stz
    'SEGSTAMP': 1,       # shsegi.s: 0 from the file on a cold spawn,
                         # SEG_MAGIC left by the run that copied the
                         # segments on a warm one -- SEG_INIT's whole
                         # cold/warm discriminator, so it MUST arrive
                         # dirty on run 2 (that is the test)
}


def sh_symbols():
    """Every symbol sh.s defines, from merlin32's own -v1 dump.

    Same technique as check_ls.liba_arena(): assemble with -v1 and read
    the dump -- in a PRIVATE tree (arena.private_listing), never beside
    the shared build/sh.bin (HYG-3: another lane's reassembly of sh.s
    deleted build/sh.bin_Output.txt between this gate's assemble and
    its read).
    Nothing here may be hardcoded -- LIBA_ZPG is the load address plus
    the image length, so it moves whenever sh's code size does, and a
    stale address poisons whatever now lives there instead, passing
    while proving nothing (learning:01M0M9R7RT22JEPP2R0Y6J9MBX).
    """
    lines = arena.private_listing('src/bin', 'sh.s', 'sh.bin_Output.txt')
    syms = {}
    byaddr = {}
    pat = re.compile(
        r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$([0-9A-Fa-f]+)\s*$')
    for line in lines:
        m = pat.match(line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
            if m.group(1) in TAIL_MARKERS:
                continue                 # an address in the file, not a cell
            byaddr.setdefault(int(m.group(2), 16), []).append(m.group(1))
    wanted = (['LIBA_ZPG', 'SH_BSSEND', 'SH_ARENA_END', 'SEG_INIT',
               'SH_SEG_LOW', 'SH_FILE_END', 'SEGSTAMP', 'PFX_RESTORE',
               'PFX_SV']
              + list(SCRATCH_CELLS)
              + list(REPL_ZERO_CELLS))
    missing = [w for w in wanted if w not in syms]
    if missing:
        raise RuntimeError(
            f'{missing} absent from sh.bin_Output.txt -- this gate names '
            f'cells that no longer exist in src/bin/sh.s. Reclassify them '
            f'rather than deleting the entry.')
    return syms, sorted(byaddr.items())


def owner(byaddr, addr):
    """The symbol at or below `addr`, for a readable report."""
    best = None
    for a, names in byaddr:
        if a > addr:
            break
        best = (a, names)
    return '?' if best is None else f'{"/".join(best[1])}+{addr - best[0]}'


def spans(syms, table):
    return [(syms[n], syms[n] + size) for n, size in table.items()]


def check_spans(syms, byaddr, table):
    """No declared cell may run past the NEXT symbol in the dump.

    The sizes above are written by hand from the `ds` operands, and a
    size that drifted -- EXPBUF is 128 today because EXPBUFLEN says so
    -- would have this gate poking $A5 over whatever now follows the
    cell, up to and including CODE. The assembler's own symbol order
    is the cheap check: a cell that ends past its successor's address
    is a stale size, not a poison target.
    """
    addrs = [a for a, _ in byaddr]
    bad = []
    for name, size in table.items():
        lo = syms[name]
        nxt = next((a for a in addrs if a > lo), None)
        if nxt is not None and lo + size > nxt:
            bad.append(f'{name} (${lo:04X}+{size}) runs past the next '
                       f'symbol at ${nxt:04X}')
    return bad


def segstamp_pass(disk, syms, sh_syms, sh_image):
    """Failures from the stamp-order check (assertion 3 above)."""
    fails = []
    stamp = sh_syms['SEGSTAMP']
    magic = sh_syms['SEG_MAGIC']
    store = bytes([0x8D, stamp & 0xFF, stamp >> 8])      # sta SEGSTAMP
    pair = bytes([0xA9, magic]) + store                  # lda #M / sta
    if sh_image.count(store) != 1 or sh_image.count(pair) != 1:
        return [f'SEGSTAMP (${stamp:04X}) must be stored by exactly one '
                f'`lda #SEG_MAGIC / sta SEGSTAMP` in sh.bin; found '
                f'{sh_image.count(store)} store(s) and '
                f'{sh_image.count(pair)} such pair(s). The stamp must '
                f'follow BOTH segment copies (shsegi.s).']
    pc = LOAD_BASE_SH + sh_image.index(pair) + 2
    want = sh_syms['SH_SEG2_END'] >> 8
    client = boot(disk)
    hits = []
    try:
        aud = TextAuditor(client, syms, {}, label='check-shwarm')
        total = 0
        while total < 2_000_000_000:
            r = client.call_tool('until_pc', {'pc': pc,
                                              'max_cycles': 40_000_000})
            total += r.get('elapsed', 40_000_000)
            if r.get('hit'):
                if not aud.in_kernel():
                    regs = client.call_tool('regs', {})
                    x = next(regs[k] for k in ('x', 'X') if k in regs)
                    hits.append(x & 0xFF)
                client.call_tool('step', {'cycles': 16})
                total += 16
                continue
            if aud.harness_cell(R_DONE)[0] in (0xAA, 0xEE):
                break
    finally:
        client.close()
    print(f'[check-shwarm] SEGSTAMP stores at ${pc:04X}: {len(hits)} '
          f'cold start(s), X at each = '
          f'{[f"${h:02X}" for h in hits]} (want ${want:02X}, the '
          f'second segment\'s end page)')
    if len(hits) < 2:
        fails.append(f'only {len(hits)} SEGSTAMP store(s) observed; the '
                     f'image has at least two cold `sh` starts (the '
                     f'outer shell and nested run 1)')
    for h in hits:
        if h != want:
            fails.append(
                f'SEGSTAMP was stored with X=${h:02X}, the end page of '
                f'the FIRST segment\'s copy, not ${want:02X}: the stamp '
                f'precedes the $D000 copy, so a sh killed between them '
                f'leaves a stamped, half-installed bank (review B2)')
            break
    return fails


def deadcopy_pass(disk, syms, sh_syms, sh_image):
    """Failures from the one-reader check on the segments' low copy.

    SH-PREFIX Phase 0 filled the dead copy ($SH_SEG_LOW..SH_FILE_END)
    with arena buffers, which is only sound if the copy is read ONCE,
    by SEG_INIT, before anything has written it.  This stops at
    SEG_INIT's entry on every `sh` start, and on each COLD one
    (SEGSTAMP still 0, as the file loaded it) requires the whole region
    to be byte-identical to the file: nothing -- not the loader, not
    the kernel's argv/envp copy -- has stored into it yet.  A warm
    start is counted and skipped (SEG_INIT does not run its copy, so
    the region is dead by design and is not compared).
    """
    lo, hi = sh_syms['SH_SEG_LOW'], sh_syms['SH_FILE_END']
    want = sh_image[lo - LOAD_BASE_SH:hi - LOAD_BASE_SH]
    head = sh_image[:16]
    entry = sh_syms['SEG_INIT']
    stamp = sh_syms['SEGSTAMP']
    client = boot(disk)
    cold, warm, fails = 0, 0, []
    seq = []                              # 'cold' / 'warm', in boot order
    try:
        aud = TextAuditor(client, syms, {}, label='check-shwarm')
        total = 0
        while total < 2_000_000_000:
            r = client.call_tool('until_pc', {'pc': entry,
                                              'max_cycles': 40_000_000})
            total += r.get('elapsed', 40_000_000)
            if r.get('hit'):
                bank = None if aud.in_kernel() else \
                    aud.peek(syms['K_CURPID'], 1)[0]   # a pid IS its bank
                if (bank is not None and aud.peek(
                        LOAD_BASE_SH, 16, 'aux', bank) == head):
                    if aud.peek(stamp, 1, 'aux', bank)[0] == 0:
                        cold += 1
                        seq.append('cold')
                        got = b''.join(
                            aud.peek(a, min(512, hi - a), 'aux', bank)
                            for a in range(lo, hi, 512))
                        diff = [lo + i for i in range(len(want))
                                if got[i] != want[i]]
                        if diff:
                            fails.append(
                                f'{len(diff)} byte(s) of the segments\' '
                                f'low copy ${lo:04X}-${hi - 1:04X} were '
                                f'already written when SEG_INIT was '
                                f'entered on a cold spawn (first '
                                f'${diff[0]:04X}, '
                                f'{owner(sh_syms["_byaddr"], diff[0])}): '
                                f'something else writes the copy before '
                                f'its one reader runs')
                    else:
                        warm += 1
                        seq.append('warm')
                client.call_tool('step', {'cycles': 16})
                total += 16
                continue
            if aud.harness_cell(R_DONE)[0] in (0xAA, 0xEE):
                break
    finally:
        client.close()
    # SH-ROOM (R5): a COLD start after a warm one. The stamp lives in the
    # image, so a cold spawn into a bank a warm sh used must find it
    # rewritten to 0 by the loader and install both segments again.
    if 'warm' not in seq or 'cold' not in seq[seq.index('warm'):]:
        fails.append(f'no COLD SEG_INIT entry after a warm one (order '
                     f'seen: {seq}): nothing shows a cold start installs '
                     f'the segments intact after warm respawns')
    print(f'[check-shwarm] SEG_INIT order: {seq}')
    print(f'[check-shwarm] SEG_INIT entered {cold} cold / {warm} warm '
          f'time(s); the {hi - lo} B low copy ${lo:04X}-${hi - 1:04X} '
          f'was byte-identical to the file at every cold entry')
    if cold < 2:
        fails.append(f'only {cold} cold SEG_INIT entry observed; the '
                     f'image has at least two cold `sh` starts')
    if warm < 1:
        fails.append('no warm SEG_INIT entry observed (run 2)')
    return fails


def pfxsv_pass(disk, syms, sh_syms, sh_image):
    """Failures from the PFX_SV initialisation check (SH-PREFIX).

    PFX_SV counts the saved prefix assignments PFX_RESTORE owes.  It is
    an arena cell, so a recycled bank hands it back dirty, and START
    must clear it (TAB-A3-NOTES sec 5 is the same lesson for TC_ON).
    Poison the whole arena of every candidate bank with $A5 BEFORE the
    boot (as the main run does), stop at every PFX_RESTORE entry in an
    `sh` and require PFX_SV <= PFX_MAX: any real count is at most the
    table, and a cell START forgot reads $A5.  Without the init the
    wrong value is visible at the very first call; the output of a
    shell that restores garbage may still look right, which is why the
    cell is read and not its consequences.
    """
    entry = sh_syms['PFX_RESTORE']
    cell = sh_syms['PFX_SV']
    arena_lo = sh_syms['LIBA_ZPG']
    span = sh_syms['SH_ARENA_END'] - arena_lo
    head = sh_image[:16]
    client = boot(disk)
    seen, worst, fails = 0, 0, []
    try:
        for bank in CAND_BANKS:
            client.call_tool('poke', {
                'addr': arena_lo, 'bytes': [POISON] * span,
                'bank': 'aux', 'aux_bank': bank})
        aud = TextAuditor(client, syms, {}, label='check-shwarm')
        total = 0
        while total < 2_000_000_000 and seen < 400:
            r = client.call_tool('until_pc', {'pc': entry,
                                              'max_cycles': 40_000_000})
            total += r.get('elapsed', 40_000_000)
            if r.get('hit'):
                bank = None if aud.in_kernel() else \
                    aud.peek(syms['K_CURPID'], 1)[0]
                if (bank is not None and aud.peek(
                        LOAD_BASE_SH, 16, 'aux', bank) == head):
                    seen += 1
                    v = aud.peek(cell, 1, 'aux', bank)[0]
                    worst = max(worst, v)
                    if v > PFX_MAX and not fails:
                        fails.append(
                            f'PFX_SV was ${v:02X} at PFX_RESTORE call '
                            f'{seen} in bank {bank}: START does not '
                            f'initialise it (the bank was poisoned '
                            f'with ${POISON:02X})')
                client.call_tool('step', {'cycles': 16})
                total += 16
                continue
            if aud.harness_cell(R_DONE)[0] in (0xAA, 0xEE):
                break
    finally:
        client.close()
    print(f'[check-shwarm] PFX_RESTORE entered {seen} time(s) in `sh`; '
          f'PFX_SV at most ${worst:02X} (limit ${PFX_MAX:02X})')
    if seen < 3:
        fails.append(f'only {seen} PFX_RESTORE call(s) observed')
    return fails


class ShWarmAuditor(TextAuditor):
    """textaudit's observer plus a hook at every process exit."""

    def __init__(self, *args, on_exit=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.on_exit = on_exit

    def observe_exit(self):
        before = len(self.observations)
        super().observe_exit()
        if self.on_exit and len(self.observations) > before:
            self.on_exit(self.observations[-1])


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else DISK
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run `make shwarm-image` first',
              file=sys.stderr)
        return 2
    # PRC_LD_FL_IMG and PRC_PATHBUF are read for the PER-SPAWN warm
    # measurement below -- see spawn_warm()'s own comment for why the
    # obvious LZ_WARM-at-exit reading is WRONG for a shell.
    syms = load_syms(SYMFILE, names=SYMS + ('PRC_LD_FL_IMG',
                                            'PRC_PATHBUF',
                                            'K_CURPID'),
                     binary=SYSBIN)
    sh_syms, byaddr = sh_symbols()
    arena = sh_syms['LIBA_ZPG']
    # SH-PREFIX: to SH_ARENA_END, not SH_BSSEND.  SH_BSSEND sits in the
    # MIDDLE of the arena (sh.s); the cells declared after it (TAB-A3's
    # TC_*, shpfx.s's PFX_*) were never poisoned, which is how TC_ON
    # reached the box unproven (TAB-A3-NOTES sec 5).
    span = sh_syms['SH_ARENA_END'] - arena
    scratch = spans(sh_syms, SCRATCH_CELLS)
    replzero = spans(sh_syms, REPL_ZERO_CELLS)

    with open(os.path.join(BUILD, 'sh.bin'), 'rb') as f:
        sh_image = f.read()
    images = {SH_PATH: ('sh', sh_image)}

    failures = []
    failures.extend(segstamp_pass(disk, syms, sh_syms, sh_image))
    sh_syms['_byaddr'] = byaddr
    failures.extend(deadcopy_pass(disk, syms, sh_syms, sh_image))
    failures.extend(pfxsv_pass(disk, syms, sh_syms, sh_image))
    failures.extend(check_spans(sh_syms, byaddr, SCRATCH_CELLS))
    failures.extend(check_spans(sh_syms, byaddr, REPL_ZERO_CELLS))
    poisoned = []
    run2_spawn = []
    client = boot(disk)
    try:
        def poison(bank):
            client.call_tool('poke', {
                'addr': arena, 'bytes': [POISON] * span,
                'bank': 'aux', 'aux_bank': bank})
            for lo, hi in scratch:
                client.call_tool('poke', {
                    'addr': lo, 'bytes': [POISON] * (hi - lo),
                    'bank': 'aux', 'aux_bank': bank})

        def spawn_warm(auditor):
            """Was the NEXT spawn served warm? Measured at its own load.

            THE OBVIOUS READING IS WRONG FOR A SHELL, and it would have
            made this gate pass vacuously. LZ_WARM is one global cell
            that PRC_ALLC_BANK stz's and the warm path sets, ONCE PER
            SPAWN -- so reading it at a process's exit describes that
            process's own spawn only if the process spawned nothing
            itself. `sh` spawns everything. Measured: all three `sh`
            exits in this boot report LZ_WARM set, including the outer
            shell whose own spawn was the first of the boot and could
            not possibly have been warm -- what the flag actually held
            was each shell's LAST CHILD's spawn.

            So the reading is taken where it is unambiguous:
            PRC_LD_FL_IMG, the loader entry, reached once per spawn
            with LZ_WARM already decided by PRC_ALLC_BANK and
            PRC_PATHBUF still holding the canonical pathname being
            spawned. Called at run 1's retire, so the spawn it catches
            is the very next one -- which is run 2 if, and only if,
            the two script lines really are adjacent. If something
            else spawned in between, this reports that program's name
            and the gate says so instead of guessing.

            in_kernel() is applied for the same reason textaudit
            applies it to LZ_RETAIN: `until_pc` matches a bare 16-bit
            PC and a process bank can hold anything at that address
            (learning:01M0MYC6NPJDYT62Q5D1M0SRKX).
            """
            for _ in range(8):
                r = client.call_tool('until_pc', {
                    'pc': syms['PRC_LD_FL_IMG'], 'max_cycles': 40_000_000})
                if not r.get('hit'):
                    return None
                if auditor.in_kernel():
                    break
                client.call_tool('step', {'cycles': 16})
            else:
                return None
            warm = auditor.peek(syms['LZ_WARM'], 1)[0]
            raw = auditor.peek(syms['PRC_PATHBUF'], 66)
            n = raw[0]
            path = ('' if n == 0 or n > 64 else
                    ''.join(chr(b & 0x7F) for b in raw[1:1 + n]).upper())
            return (path, warm)

        def on_exit(obs):
            # Only `sh` retires matter, and only the FIRST one: that is
            # nested run 1 dying, with run 2's spawn the very next
            # thing the outer shell does.
            if obs.path != SH_PATH or poisoned:
                return
            poison(obs.bank)
            back = bytes(client.call_tool('peek', {
                'addr': arena, 'count': 8, 'bank': 'aux',
                'aux_bank': obs.bank})['bytes'])
            cell = bytes(client.call_tool('peek', {
                'addr': scratch[0][0], 'count': 1, 'bank': 'aux',
                'aux_bank': obs.bank})['bytes'])
            poisoned.append((obs.bank, back, cell))
            print(f'[check-shwarm] run 1 retired in bank {obs.bank}: '
                  f'poisoned the arena ${arena:04X}+{span} AND '
                  f'{len(scratch)} emitted scratch cells with '
                  f'${POISON:02X}, between run 1\'s death and run 2\'s '
                  f'spawn')
            got = spawn_warm(auditor)
            run2_spawn.append(got)
            print(f'[check-shwarm] the NEXT spawn after run 1 died: '
                  f'{got}')

        # -- THE PRE-BOOT POISON. Every candidate child bank, so run 1
        # -- itself starts on $A5 rather than on whatever the bank
        # -- happened to hold.
        print(f'[check-shwarm] poisoning sh\'s arena ${arena:04X}+{span} '
              f'(LIBA_ZPG..SH_ARENA_END) with ${POISON:02X} in aux banks '
              f'{CAND_BANKS.start}-{CAND_BANKS.stop - 1}')
        for bank in CAND_BANKS:
            client.call_tool('poke', {
                'addr': arena, 'bytes': [POISON] * span,
                'bank': 'aux', 'aux_bank': bank})

        auditor = ShWarmAuditor(client, syms, images, label='check-shwarm',
                                on_exit=on_exit)
        status = auditor.run()
        warm = auditor.peek(syms['LZ_WARM'], 1)[0]
    finally:
        client.close()

    sh_exits = [o for o in auditor.observations if o.path == SH_PATH]
    print(f'[check-shwarm] done=${status["done"]:02X} '
          f'err=${status["err"]:02X} step={status["step"]} '
          f'sh exits={len(sh_exits)} LZ_WARM=${warm:02X}')

    if status['done'] != 0xAA:
        failures.append(
            f'the harness did not finish (done=${status["done"]:02X} '
            f'err=${status["err"]:02X} step={status["step"]}). Nothing this '
            f'run measured can be trusted.')
    # THREE `sh` exits, in order: nested run 1, nested run 2, and the
    # outer shell the harness spawned (which is alive throughout and
    # therefore exits last). Fewer means a nested shell never ran --
    # `sh` cannot spawn `sh`, or the script never reached the line.
    # SH-ROOM (R5) added nested #3 (warm) and #4 (cold, spawned by #3
    # while #3 is live): exits run1, run2, #4, #3, outer.
    if len(sh_exits) != 5:
        failures.append(
            f'expected exactly 5 `sh` process exits (nested run 1, nested '
            f'run 2, nested #4, nested #3, then the outer shell) and saw '
            f'{len(sh_exits)}. Without two nested shells there is no '
            f'repeat pair at all.')
    run1 = sh_exits[0] if sh_exits else None
    run2 = sh_exits[1] if len(sh_exits) > 1 else None

    if run1 and run2:
        # A pid IS its bank (src/kernel/process.s), so this is what
        # makes "the bank we poisoned" and "the bank run 2 reused" the
        # same bank. Without it the poison went somewhere run 2 never
        # touched and the gate is vacuous, not merely weaker.
        if run1.bank != run2.bank:
            failures.append(
                f'run 1 died in bank {run1.bank} but run 2 ran in bank '
                f'{run2.bank} -- the retained bank was NOT reused, so the '
                f'poison landed where run 2 never looked and the repeat '
                f'pair proves nothing about warm respawn.')
    # THE WARM GUARD, from the per-spawn reading (spawn_warm()'s own
    # comment says why the flag cannot be read at a SHELL's exit).
    if not run2_spawn:
        failures.append(
            'no spawn was observed after run 1 died, so nothing here '
            'establishes that run 2 was served warm')
    else:
        got = run2_spawn[0]
        if got is None:
            failures.append(
                'the loader was never reached again after run 1 died -- '
                'run 2 never spawned at all')
        else:
            path, warm = got
            if path != SH_PATH:
                failures.append(
                    f'the first spawn after run 1 died was {path!r}, not '
                    f'{SH_PATH}. The two `SH` lines must be ADJACENT: '
                    f'anything spawned between them can reclaim the bank '
                    f'and make run 2 cold, which passes while proving '
                    f'nothing.')
            if not warm:
                failures.append(
                    'the kernel\'s LZ_WARM was CLEAR at run 2\'s own load: '
                    'the second nested `sh` was served COLD -- a freshly '
                    'copied image -- so its output matching run 1 says '
                    'nothing about the retained bank. Either lazy free '
                    'stopped retaining `sh` (did its entry head start '
                    'moving?) or something reclaimed the bank between the '
                    'two spawns.')
    if not poisoned:
        failures.append(
            'the poison never fired: no `sh` bank retire was observed, so '
            'nothing was scribbled between the two runs')
    for bank, back, cell in poisoned:
        if any(b != POISON for b in back):
            failures.append(
                f'the ${POISON:02X} arena poke into bank {bank} read back '
                f'as {list(back)} -- it did not land, so run 2 proved '
                f'nothing about uninitialised reads')
        if cell[0] != POISON:
            failures.append(
                f'the ${POISON:02X} poke into bank {bank}\'s first emitted '
                f'scratch cell read back as ${cell[0]:02X} -- the image-cell '
                f'poison did not land')
    # CORROBORATION ONLY, and deliberately labelled as such: at the end
    # of a boot LZ_WARM describes the LAST spawn of that boot, which
    # here is one of the outer shell's children, not run 2. It is worth
    # one line -- clear means the no-copy path was never taken by
    # ANYTHING, which would make the whole boot suspect -- but the
    # guard that matters is the per-spawn reading above.
    if warm == 0:
        failures.append(
            'the kernel\'s LZ_WARM is clear at the end of the boot: no '
            'spawn in it was served out of a retained bank at all')

    # -- the repeat pair -------------------------------------------
    vol = a2til.open_image(disk)
    out = {}
    for name in (bs.OUT1, bs.OUT2):
        try:
            out[name] = bytes(vol.read_file(name))
        except FileNotFoundError:
            out[name] = None
    a, b = out[bs.OUT1], out[bs.OUT2]
    try:
        out4 = bytes(vol.read_file(bs.OUT4))
    except FileNotFoundError:
        out4 = None
    print(f'[check-shwarm] {bs.OUT1}: '
          f'{"MISSING" if a is None else str(len(a)) + " B"}   '
          f'{bs.OUT2}: {"MISSING" if b is None else str(len(b)) + " B"}')
    if a:
        print('[check-shwarm] run 1 output:')
        for line in a.split(b'\x8d'):
            if line:
                print('    ' + ''.join(chr(c & 0x7F) for c in line))
    if a is None:
        failures.append(
            f'{bs.OUT1} does not exist -- the FIRST nested `sh` wrote no '
            f'output at all, so there is no expectation to compare against')
    else:
        # EVERY PAIRED PROGRAM MUST HAVE PRODUCED SOMETHING RECOGNISABLE.
        # Two files of identical garbage compare equal: a boot in which
        # every command was "not found" would pass a bare equality test.
        text = ''.join(chr(c & 0x7F) for c in a)
        for marker in bs.MARKERS:
            if marker not in text:
                failures.append(
                    f'run 1\'s output is missing the marker {marker!r} -- '
                    f'the sub-script did not do what this gate compares. '
                    f'Got: {text!r}')
    # SH-ROOM (R5): nested #4, the COLD start after a warm one, must
    # have installed both segments (TYPE/EVAL/TEST markers are printed by
    # segment code) and an empty, working alias table.
    if out4 is None:
        failures.append(f'{bs.OUT4} does not exist -- nested #4 (the cold '
                        f'start after the warm ones) wrote no output')
    else:
        text4 = ''.join(chr(c & 0x7F) for c in out4)
        for marker in bs.MARKERS4:
            if marker not in text4:
                failures.append(f'nested #4 (cold after warm): output is '
                                f'missing {marker!r}. Got: {text4!r}')
        if text4.count('alias ') != 1:
            failures.append(f'nested #4 listed {text4.count("alias ")} '
                            f'`alias ` line(s), expected exactly 1: the '
                            f'table was not empty at its cold START')
    if a is not None:
        # SH-ROOM: the sub-script lists the alias table twice, once before
        # and once after defining ZZ. Exactly ONE `alias ` line in run 1
        # means the table was EMPTY at START (cold: the dead copy held
        # the segment tails; ALI_INIT cleared it).
        listed = ''.join(chr(c & 0x7F) for c in a).count('alias ')
        if listed != 1:
            failures.append(
                f'run 1 listed {listed} `alias ` line(s), expected exactly '
                f'1 (ZZ, after its definition): the alias table was not '
                f'empty at START -- ALI_INIT did not run, or did not empty '
                f'every slot, over the segments\' dead copy')
    if a is not None and b != a:
        gotb = 'no output file at all' if b is None else repr(
            ''.join(chr(c & 0x7F) for c in b))
        failures.append(
            f'THE SECOND nested `sh` -- byte-identical script, byte-'
            f'identical argv, served warm out of the bank the first left '
            f'behind -- did not reproduce the first.\n'
            f'  run 1 = {"".join(chr(c & 0x7F) for c in a)!r}\n'
            f'  run 2 = {gotb}\n'
            f'  This is docs/STICKY.md sec 27\'s residual arriving on '
            f'`sh`: the text was reused without being recopied and a cell '
            f'was read that this run did not write.')

    # -- every moved image byte classified --------------------------
    print(f'[check-shwarm] `sh` image {len(sh_image)} B; moved bytes per '
          f'exit:')
    unclassified = set()
    for i, obs in enumerate(sh_exits):
        which = ('nested run 1', 'nested run 2', 'nested #4 (cold)',
                 'nested #3 (warm)', 'the outer shell')[i] \
            if i < 5 else f'exit {i}'
        moved = obs.diffs or []
        # NOT obs.warm: that is LZ_WARM read at a SHELL's exit, which
        # describes its last CHILD's spawn (spawn_warm()'s comment).
        print(f'   {which}: bank {obs.bank}, {len(moved)} moved')
        for off in moved:
            addr = 0x800 + off
            klass = ('scratch' if any(lo <= addr < hi for lo, hi in scratch)
                     else 'repl-zero'
                     if any(lo <= addr < hi for lo, hi in replzero)
                     else 'dead-copy'
                     if (DEAD_POISONED
                         and sh_syms['SH_SEG_LOW'] <= addr
                         < sh_syms['SH_FILE_END'])
                     else 'UNCLASSIFIED')
            print(f'        ${addr:04X}  {owner(byaddr, addr):<24} {klass}')
            if klass == 'UNCLASSIFIED':
                unclassified.add(addr)
    for addr in sorted(unclassified):
        failures.append(
            f'${addr:04X} ({owner(byaddr, addr)}) is an image byte `sh` '
            f'moved that this gate does not classify. Every moved byte is '
            f'either SCRATCH (written before read this run -- add it to '
            f'SCRATCH_CELLS, where the poison will test that claim) or a '
            f'REPL ZERO (read on the first pass -- add it to '
            f'REPL_ZERO_CELLS and make sh\'s own entry establish it). An '
            f'unclassified one is an unproven warm claim.')

    if failures:
        for f in failures:
            print(f'[check-shwarm] FAIL: {f}', file=sys.stderr)
        return 1
    print(f'[check-shwarm] PASS: `sh` spawned `sh` TWICE in one boot, '
          f'adjacently, from byte-identical scripts with byte-identical '
          f'argv. Run 2 was served WARM out of run 1\'s retained bank '
          f'(bank {run1.bank}, LZ_WARM set at its OWN load) after that '
          f'bank\'s whole uncleared arena ({span} B, LIBA_ZPG..SH_ARENA_END) '
          f'AND all {len(scratch)} of `sh`\'s surviving emitted scratch '
          f'cells were scribbled with ${POISON:02X} -- and its output is '
          f'byte-identical to run 1\'s ({len(a)} B). Every moved image '
          f'byte is classified.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
