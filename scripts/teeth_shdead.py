#!/usr/bin/env python3
"""teeth_shdead.py -- the sabotage runner behind SH-PREFIX Phase 0's
dead-copy placement (docs/SH-PREFIX-NOTES.md sec 2) and SH-ROOM/SH-ROOM2's
placements, on scripts/teeth_lib.py (HYG-4). NOT a gate and in no sweep:
it edits src/bin/shlex.s / sh.s / ... and scripts/check_shwarm.py,
rebuilds, runs the named gates and requires each tooth's verdicts, with
the sabotaged sh.bin DIFFERING from the good one (a [static] tooth edits
an equate that emits no byte: the witness is that sh.bin did NOT move).
It restores from the captured bytes (never `git checkout`) and the final
rebuild must reproduce the good sh.bin. Exit status: teeth_lib.py (0 all
behaved, 1 a tooth did not bite, 2 runner broken).

A gate named `gate:needle` must be red AND print `needle` on a
`[check-X] FAIL:` line (the history ring and the alias table share one
error path, so a static tooth cannot go red for the wrong reason).

  python3 scripts/teeth_shdead.py            # all
  python3 scripts/teeth_shdead.py P1 D2      # by name prefix
  python3 scripts/teeth_shdead.py --dry
  python3 scripts/teeth_shdead.py --observe D2   # what each gate printed

P1 is the odd one out: it is the PROOF, not a sabotage. It poisons the
whole dead copy with $A5 right after SEG_INIT returns (cold AND warm,
since START runs it every time) and expects the gates to stay GREEN --
nothing reads the copy afterwards. P2 is its control: the same poison
BEFORE SEG_INIT corrupts the segments it is about to copy, and must turn
the SAME gates RED, which shows the poison reaches the live bytes (a
green gate only counts where its twin was seen red).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

LX = 'src/bin/shlex.s'
SH = 'src/bin/sh.s'
SW = 'scripts/check_shwarm.py'

POISON_LOOP = """\
            lda   #<SH_SEG_LOW
            sta   PTR1
            lda   #>SH_SEG_LOW
            sta   PTR1+1
:pz         lda   #$A5
            sta   (PTR1)
            inc   PTR1
            bne   :pz1
            inc   PTR1+1
:pz1        lda   PTR1
            cmp   #<SH_FILE_END
            bne   :pz
            lda   PTR1+1
            cmp   #>SH_FILE_END
            bne   :pz
"""
CALL = "            jsr   SEG_INIT\n"

# (name, file, edits, gates, expect) -- expect 'green' or 'red'
SPECS = [
 ('P1 PROOF: poison the dead copy with $A5 right after SEG_INIT '
  '(cold and warm)', LX, [(CALL, CALL + POISON_LOOP)],
  ['shwarm', 'play', 'tabcomp', 'shedit', 'shlang'], 'green'),
 ('P2 CONTROL: the same poison BEFORE SEG_INIT corrupts the segments',
  LX, [(CALL, POISON_LOOP + CALL)],
  ['shwarm', 'play', 'tabcomp', 'shedit', 'shlang'], 'red'),
 ('D1 a store into the copy before its one reader runs '
  '(`sta $8F00` ahead of SEG_INIT)', LX,
  [(CALL, "            lda   #$01\n            sta   $8F00\n" + CALL)],
  ['shwarm'], 'red'),
 ('D2 a moved cell back in the arena: the inside-the-copy check',
  SH, [("LINEBUF     ds    LINEMAX+1\nTOKPTR      ds    MAXTOK*2\n"
        "HD_BODY", "TOKPTR      ds    MAXTOK*2\nHD_BODY"),
       ("*-- LINEBUF: moved, see the dead-copy block\n",
        "LINEBUF     ds    LINEMAX+1\n")],
  ['modules'], 'red'),
 ('A1 SH-ROOM: START never empties the alias table (no ALI_INIT)',
  LX, [("            jsr   ALI_INIT               ;empty alias table\n", "")],
  ['shwarm'], 'red'),
 ('A2 SH-ROOM: ALI_INIT forgets the last name slot',
  'src/bin/shsgali.s', [("            cmp   #128\n            bne   :z\n",
                         "            cmp   #112\n            bne   :z\n")],
  ['shwarm'], 'red'),
 # SH-ROOM2: D1b stored a constant ($01); the file byte under ALI_NAMES
 # became $01 after the layout moved, so the store changed nothing and
 # the tooth went green. A COMPLEMENT write cannot coincide.
 ('D1b SH-ROOM: a store into the alias table before SEG_INIT reads the copy',
  LX, [(CALL, "            lda   ALI_NAMES\n            eor   #$FF\n"
              "            sta   ALI_NAMES\n" + CALL)],
  ['shwarm:already written when SEG_INIT'], 'red'),
 ('D4 SH-ROOM: the alias block OUTSIDE the dead copy (below SH_SEG_LOW)',
  SH, [("            dum   $6E78\n", "            dum   $6700\n"),
       ("            dum   $6C78\n", "            dum   $64F8\n")],
  ['modules:is not inside the segments'], 'red'),
 ('F1 SH-ROOM: ALI_FIND takes an empty name for a free slot again',
  'src/bin/shsgali.s', [("ALI_FIND    lda   (PTR0)\n            bne   :nz\n            sec\n            rts\n:nz         stz   ALIDX\n",
                         "ALI_FIND    stz   ALIDX\n")],
  ['shlang'], 'red'),
 ('C1 SH-ROOM: the shared error tail drops the status',
  'src/bin/shpath.s', [("PR_ERRAX1   jsr   PR_ERRAX\n            lda   #1\n            sta   LASTSTATUS\n",
                        "PR_ERRAX1   jsr   PR_ERRAX\n            lda   #1\n")],
  ['shlang'], 'red'),
 ('C2 SH-ROOM: a converted SB_MATCH caller loses its carry contract (echo)',
  'src/bin/shbltn.s', [("            jsr   SB_MATCH\n            bcc   :isecho\n",
                        "            jsr   SB_MATCH\n            bcs   :isecho\n")],
  ['shlang'], 'red'),
 ('E1 SH-ROOM: EMIT_DUP0_A no longer preserves X',
  'src/bin/shblt2.s', [("EMIT_DUP0_A phx ", "EMIT_DUP0_A nop "),
                       ("EMIT_DUPX   jsr   EMIT_DUP_A\n            plx\n",
                        "EMIT_DUPX   jsr   EMIT_DUP_A\n            nop\n")],
  ['shfd', 'shlang'], 'red'),
 ('S1 SH-ROOM: CS_SEEKHEAD multiplies the frame by 2, not 3',
  'src/bin/shresv.s', [("CS_SEEKHEAD\n            txa\n            sta   CSTMP\n            clc\n            adc   CSTMP\n            clc\n            adc   CSTMP\n",
                        "CS_SEEKHEAD\n            txa\n            sta   CSTMP\n            clc\n            adc   CSTMP\n            nop\n            nop\n            nop\n")],
  ['shlang'], 'red'),
 ('R1 SH-ROOM: SG_RDFETCH has its dangling test inverted',
  'src/bin/shsub2.s', [("            bcs   :rdx                   ;dangling -- carry set\n",
                        "            bcc   :rdx                   ;dangling -- carry set\n")],
  ['shlang'], 'red'),
 ('Z1 SH-ROOM: no cold start after a warm one (the nested #3/#4 line gone)',
  'scripts/build_shwarm_image.py',
  [("    f'SH < /mnt/{CARRIER_VOL}/SUB3',\n", "")], ['shwarm'], 'red'),
 ('D4n SH-ROOM: D4 again with NO built sh.bin (check-modules is static)',
  SH, [("            dum   $6E78\n", "            dum   $6700\n"),
       ("            dum   $6C78\n", "            dum   $64F8\n")],
  ['modules_nobin:is not inside the segments'], 'red'),
 ('L1 SH-ROOM2 [static] SH_SEG2_LIM moved off the bank boundary',
  SH, [("SH_SEG2_LIM equ   PRC_LC_COMMON\n",
        "SH_SEG2_LIM equ   PRC_LC_COMMON+$100\n")],
  ['modules_nobin:SH_SEG2_LIM is'], 'red'),
 # ---- SH-ROOM2 step 3 (C-H3): the history ring in the dead copy ----
 ('D5 SH-ROOM2: ONLY the ring outside the dead copy (below SH_SEG_LOW)',
  SH, [("            dum   $6C78\n", "            dum   $6700\n")],
  ['modules:ED_HRING'], 'red'),
 ('D5n SH-ROOM2: D5 again with NO built sh.bin',
  SH, [("            dum   $6C78\n", "            dum   $6700\n")],
  ['modules_nobin:ED_HRING'], 'red'),
 ('D6 SH-ROOM2 [static]: the ring overlaps the alias table (err gone)',
  SH, [("            dum   $6C78\n", "            dum   $6D78\n"),
       ("            err   */ALI_NAMESP1\n", "")],
  ['modules_nobin:overlaps the alias table'], 'red'),
 ('D1c SH-ROOM2: a complement write to the RING before SEG_INIT reads it',
  LX, [(CALL, "            lda   ED_HRING\n            eor   #$FF\n"
              "            sta   ED_HRING\n" + CALL)],
  ['shwarm:already written when SEG_INIT'], 'red'),
 ('H2 SH-ROOM2: the ring is 256 B (ED_HSIZE $0100): size pin + histcap',
  SH, [("ED_HSIZE    equ   $0200\n", "ED_HSIZE    equ   $0100\n")],
  ['modules_nobin:ED_HSIZE', 'shedit_histcap:FAIL shedit histcap'], 'red'),
 ('H1 SH-ROOM2: ED_INIT stops clearing ED_HN/ED_HUSED (rest kept): the '
  'same-bank warm history row',
  'src/bin/shedit.s',
  [("            stz   ED_HN\n            stz   ED_HUSED\n"
    "            stz   ED_HUSED+1\n", "")],
  ['shedit_hist:FAIL shedit hist'], 'red'),
 # ---- SH-ROOM2 step 2b: where the cold bundle lives -----------------
 ('M1 SH-ROOM2 [static]: PFX_MANY_M moves INTO the segment',
  None,
  [('src/bin/shpfx.s',
    'PFX_MANY_M  asc   "sh: too many assignments"\n'
    '            dfb   $8D,0\n', ''),
   ('src/bin/shsgcld.s',
    'SETEOFF_STR  asc   "+E"\n             dfb   0\n',
    'SETEOFF_STR  asc   "+E"\n             dfb   0\n'
    'PFX_MANY_M  asc   "sh: too many assignments"\n'
    '            dfb   $8D,0\n')],
  ['modules_nobin:PFX_MANY_M'], 'red'),
 ('M2 SH-ROOM2 [static]: the cold bundle is `put` back into the low image',
  SH, [("            put   shedit2.s\n            put   shsgcld.s\n"
        "SH_SEG2_END", "            put   shedit2.s\nSH_SEG2_END"),
       ("            put   shsegi.s\n",
        "            put   shsegi.s\n            put   shsgcld.s\n")],
  ['modules_nobin:PFX_REC'], 'red'),
 # SH-ROOM2: FFXX_PAGE-$100 no longer builds (segment 1 is 7,875 B, the
 # lowered wall 7,680): widen it instead; the pin is the same.
 ('L2 SH-ROOM [static] SH_SEG1_LIM no longer the kernel door',
  SH, [("SH_SEG1_LIM equ   FFXX_PAGE", "SH_SEG1_LIM equ   FFXX_PAGE+$100")],
  ['modules_nobin:SH_SEG1_LIM is'], 'red'),
 ('D3 a moved cell dropped from the poison list: UNCLASSIFIED',
  SW, [("    'LINEBUF': 256,\n", "")], ['shwarm'], 'red'),
]


def fail(tag, needle=None):
    """The anchored failure line of an aggregate gate."""
    return r'^\[%s\] FAIL: ' % tag + (
        '.*' + re.escape(needle) if needle else '')


def gate(token, poisoned='0'):
    """A gate token (optionally `name:needle`) -> a Check."""
    name, _, needle = token.partition(':')
    mk = lambda cmd, tag, **kw: T.Check(  # noqa: E731
        T.Invocation(cmd, **kw.pop('inv', {})), 'aggregate',
        T.Aggregate(fail(tag, needle), 'the gate prints one FAIL line per '
                    'problem and no row ids'))
    if name == 'play':           # fails by the harness's screen-wait timeout
        return T.Check('make check-play', 'assertion', T.Aggregate(
            r'^RuntimeError: timed out waiting for shell prompt',
            'check-play prints no row ids; a shell that cannot boot makes '
            'its screen wait raise'))
    if name == 'shlang':
        c = mk('make check-shlang', 'check-shlang[a-z-]*')
        c.tag = 're:check-shlang(?:-[a-z]+)?'     # three stages, one gate
        return c
    if name == 'shfd':
        return mk('make check-shfd', 'check-shfd')
    if name == 'shwarm':
        return mk('make check-shwarm', 'check-shwarm',
                  inv={'env': {'SHDEAD_POISONED': poisoned}})
    if name == 'modules':
        return mk('python3 scripts/check_modules.py', 'check-modules')
    if name == 'modules_nobin':     # review M: a CLEAN tree
        return mk('python3 scripts/check_modules.py', 'check-modules',
                  inv={'setup': ('rm -f build/sh.bin',)})
    rows = {'tabcomp': ('make check-tabcomp', 'cmd [text40]'),
            'shedit': ('make check-shedit', 'modes [text40]'),
            'shedit_hist': ('python3 scripts/check_shedit.py text40 hist',
                            'hist [text40]'),
            'shedit_histcap': ('python3 scripts/check_shedit.py text40 '
                               'histcap', 'histcap [text40]')}[name]
    return rows


def tooth(name, fn, edits, gates, expect):
    green = expect == 'green'
    edits = [e if len(e) == 3 else (fn, e[0], e[1]) for e in edits]
    # D2 puts a cell back where its tombstone comment stands: the old
    # span is comment text by design, the new text is the code
    edits = [T.Edit(*e, comment_ok='replaces a tombstone comment with '
                    'the code it stands for') if e[1].startswith('*--')
             else T.Edit(*e) for e in edits]
    poisoned = '1' if name.startswith(('P1', 'P2')) else '0'
    checks = []
    for g in gates:
        c = gate(g, poisoned)
        if isinstance(c, tuple):            # a row-printing gate
            cmd, row = c
            c = T.Check(cmd, 'namerows', T.Rows(
                **({'controls': [row]} if green else {'red': [row]})))
        checks.append(c)
    # only L1/L2 edit an equate that emits no byte; D6/M1/M2 are tagged
    # [static] (check-modules is the subject) but DO move sh.bin
    static = name.split()[0] in ('L1', 'L2')
    kw = {}
    if name.startswith('P1'):
        kw = dict(outcome=T.GREEN_PROOF, pair='P2 CONTROL: the same poison '
                  'BEFORE SEG_INIT corrupts the segments')
    if static:
        kw['witness'] = T.Unchanged(['build/sh.bin'])
    if any(e.file == SW for e in edits):
        kw['witness'] = T.SourceOnly()      # the gate's own table
    if any(e.file == 'scripts/build_shwarm_image.py' for e in edits):
        # the image carries file dates, so its hash moves on every build
        # and could not witness anything: the edit is to the builder
        # script, and the red shwarm row is the evidence
        kw['witness'] = T.SourceOnly()
    return T.Tooth(name, edits=edits, checks=checks, **kw)


T.main('shdead', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image', 'shwarm-image'),
       artifacts=['build/sh.bin'])
