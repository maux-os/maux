#!/usr/bin/env python3
"""teeth_openrw2.py -- the sabotage runner behind check-openrw2 and
check-openrw2-k's teeth (docs/OPEN-RW-2-NOTES.md sec 9), on
scripts/teeth_lib.py (HYG-4). NOT a gate and in no sweep: it edits
kernel sources (or a census file, which needs no build), rebuilds the
play image, runs ONE gate and requires the tooth's named rows RED, with
the sabotaged artifact DIFFERING from the good one. It restores from the
captured bytes and the final rebuild must reproduce the good artifacts.
Rows are exact ids the gate prints (check-openrw2[-k] print PASS/FAIL
per row, so every named row must go red: the legacy ANY was measured
to hold ALL for all 19 teeth); the census gate prints only failure
bullets (`src/bin/tail.s:255: ..`), so it keeps ANY; check-more fails
by an AssertionError and no verdict line (reporter `assertion`). Exit
status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner
broken).

  python3 scripts/teeth_openrw2.py            # all
  python3 scripts/teeth_openrw2.py K3 K7      # by name token
  python3 scripts/teeth_openrw2.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

F2 = 'src/kernel/procfile2.s'
F3 = 'src/kernel/procfile3.s'
F4 = 'src/kernel/procfile4.s'
FD2 = 'src/kernel/procfd2.s'
KK = 'python3 scripts/check_openrw2_k.py '
SS = 'python3 scripts/check_openrw2.py '


CEN = 'scripts/open_census.txt'
MORE = 'src/bin/moreio.s'
CAT = 'src/bin/cat.s'
TAIL = 'src/bin/tail.s'

# (name, file, [(old, new)], gate command, rows that must be red)
# a spec may end with an artifact path (default: the kernel) whose
# bytes must differ, or None when the sabotaged file is not built
SPECS = [
 ('U1 the census entry for tail removed (census gate red)', CEN,
  [("bin/tail.s OPARM ro", "bin/taiX.s OPARM ro")],
  'python3 scripts/check_open_census.py', ['src/bin/tail.s'], None),
 ('U2 cat back to no intent (census says ro: census red)', CAT,
  [("INITPARMS   lda   #OPEN_RO             ;read intent: cat only\n",
    "INITPARMS   lda   #PCOUNT_OPEN\n")],
  'python3 scripts/check_open_census.py', ['src/bin/cat.s'], None),
 ('U3 more\'s spill file opened with a constant OPEN_RO (check-more red)',
  MORE,
  [("            lda   #PCOUNT_OPEN           ;a spill / cmd file is\n",
    "            lda   #OPEN_RO               ;a spill / cmd file is\n")],
  'make check-more', [''], 'build/more.bin'),
 ('U4 tail back to no intent (W2 red)', TAIL,
  [("OPARM       dfb   OPEN_RO", "OPARM       dfb   PCOUNT_OPEN")],
  SS + 'W2', ['W2'], 'build/tail.bin'),
 ('K1 admission looks at the FIRST peer only (order b, c red)', F4,
  [("            bcs   :cnt\n", "            nop\n            nop\n")],
  KK + 'order', ['order']),
 ('K2 :join keeps OFTF_RO for a writer (W1 red)', F3,
  [("            lda   #OFTF_MG       ;keeps its own intent bit: a\n"
    "            tsb   PRC_ROI        ;joining writer must not be RO\n",
    "            lda   #OFTF_RO+OFTF_MG\n            sta   PRC_ROI\n")],
  SS + 'W1', ['W1']),
 ('K3 READ at a virtual mark is an error, not 0 bytes (trunc red)', F2,
  [("            bne   :rts             ;VIRTUAL mark (the file was\n",
    "            bra   :rts             ;VIRTUAL mark (the file was\n")],
  KK + 'trunc', ['trunc']),
 ('K4 GET_EOF acquires the member\'s mark (trunc red)', F3,
  [(":isfile     jsr   PRC_OFT_RES      ;OPEN-RW-2: EOF is an FCB\n",
    ":isfile     jsr   PRC_OFT_REF      ;OPEN-RW-2: EOF is an FCB\n")],
  KK + 'trunc', ['trunc']),
 ('K5 the writer\'s FLUSH result is dropped (closeA red)', FD2,
  [("            jsr   PRC_FLUSH_A\n            bcc   :refx\n"
    "            sta   K_CLSERR\n", "            jsr   PRC_FLUSH_A\n")],
  KK + 'closeA', ['closeA']),
 ('K6 a NON-final close of the writer entry FLUSHes (fork2 red)', FD2,
  [("            lda   OFT_REFCNT,x\n            bne   :done\n",
    "            lda   OFT_REFCNT,x\n            beq   :fin\n"
    "            lda   OFT_TYPE,x\n            cmp   #OFT_FILE\n"
    "            bne   :nf\n            lda   OFT_PIPE,x\n"
    "            bmi   :nf\n            lda   OFT_REFNUM,x\n"
    "            jsr   PRC_FLUSH_A\n            bcc   :nf\n"
    "            sta   K_CLSERR\n:nf         jmp   :done\n:fin\n")],
  KK + 'fork2', ['fork2']),
 ('K7 a failed final CLOSE frees the page (closeC red)', FD2,
  [("            jsr   PCLS_RAWREF_A\n            bcs   :qfail\n",
    "            jsr   PCLS_RAWREF_A\n            nop\n            nop\n")],
  KK + 'closeC', ['closeC']),
 ('K8 a $4D from a NON-member also reads 0 bytes (nm4d red)', F2,
  [("            bvc   :rts             ;other $4D stays an error.\n",
    "            nop\n            nop\n")],
  KK + 'nm4d', ['nm4d']),
 ('K9 the unpark of a virtual member fails (truncpark red)', FD2,
  [("            bvs   :ok                  ;the slot, reopen at 0\n",
    "            nop\n            nop\n")],
  KK + 'truncpark', ['truncpark']),
 ('K10 SET_MARK loads the old mark first (trunc red)', F3,
  [(":isfile     jsr   PRC_OFT_RES      ;OPEN-RW-2: no mark load,\n",
    ":isfile     jsr   PRC_OFT_REF      ;OPEN-RW-2: no mark load,\n")],
  KK + 'trunc', ['trunc']),
 ('K11 GET_MARK of a member always swaps the mark in (trunc red)', F3,
  [("            beq   :live            ;mark answers from its slot:\n",
    "            bra   :live            ;mark answers from its slot:\n")],
  KK + 'trunc', ['trunc']),
 ('K12 a freed holder stays named in K_ROOWN (roown red)', FD2,
  [("            cpx   K_ROOWN          ;OPEN-RO: the holder is gone\n"
    "            bne   :done\n            sta   K_ROOWN\n", "")],
  KK + 'roown', ['roown']),
 ('K14 the unpark\'s leaked page is not counted (leak2 red)', FD2,
  [("            inc   K_QUAR_CNT          ;LEAK the buffer (counted:\n",
    "            nop\n            nop\n            nop                       ;LEAK the buffer (counted:\n")],
  KK + 'leak2', ['leak2']),
 ('K15 a SUCCESSFUL cleanup is counted too (leak1 red)', FD2,
  [("            bcc   :freed               ;this CLOSE ALSO fails,\n",
    "            nop\n            nop                        ;this CLOSE ALSO fails,\n")],
  KK + 'leak1', ['leak1']),
 ('K13 DESTROY / RENAME never see an open file (park red)', FD2,
  [("PRC_FILE_BUSY\n            jsr   PRC_FILE_FIND\n            bcc   :ok\n",
    "PRC_FILE_BUSY\n            jsr   PRC_FILE_FIND\n            bra   :ok\n")],
  KK + 'park', ['park']),
]


def tooth(name, fn, edits, cmd, rows, art='build/MAUXPLAY.SYSTEM'):
    # an edit is (old, new) on `fn`, or (file, old, new)
    edits = [e if len(e) == 3 else (fn, e[0], e[1]) for e in edits]
    if 'check_open_census' in cmd:
        chk = T.Check(cmd, 'bullets_only', T.Rows(red=rows, rule=T.ANY))
    elif cmd == 'make check-more':
        chk = T.Check(cmd, 'assertion', T.Aggregate(
            r'^AssertionError: timed out waiting for pipe: first screen',
            'check-more prints no verdict line: it fails by an '
            'AssertionError'))
    else:
        chk = T.Check(cmd, 'tagged', T.Rows(red=rows))
    if art is None:                      # the census file: nothing to build
        return T.Tooth(name, edits=edits, checks=[chk], prep=T.NoBuild(),
                       artifacts=(), witness=T.SourceOnly())
    return T.Tooth(name, edits=edits, checks=[chk], artifacts=[art])


T.main('openrw2', [tooth(*s) for s in SPECS], match=T.TOKEN,
       prep=T.Make('play-image'), artifacts=['build/MAUXPLAY.SYSTEM'])
