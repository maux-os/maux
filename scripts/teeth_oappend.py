#!/usr/bin/env python3
"""teeth_oappend.py -- the sabotage runner behind check-oappend
(docs/OAPPEND-1-NOTES.md sec 8), on scripts/teeth_lib.py (HYG-4). NOT a
gate and in no sweep: it edits kernel sources, rebuilds the play image,
runs the gate(s) and requires the tooth's named modes/rows RED, with the
sabotaged artifact DIFFERING from the good one. It restores from the
captured bytes (never `git checkout`) and the final rebuild must
reproduce the good artifacts. check-oappend, check-oappend-sh and
check-openrw2 print PASS/FAIL per mode/row, so every named row must go
red (the legacy ANY was measured to hold ALL for all 32 teeth); the
census prints only failure bullets and keeps ANY; the two composite
shell commands of S12/S13 are two checks now. Exit status:
teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner broken).

  python3 scripts/teeth_oappend.py            # all
  python3 scripts/teeth_oappend.py T1 T3      # by name token
  python3 scripts/teeth_oappend.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

F3 = 'src/kernel/procfile3.s'
F4 = 'src/kernel/procfile4.s'
FD2 = 'src/kernel/procfd2.s'
MLI3 = 'src/kernel/procmli3.s'
KK = 'python3 scripts/check_oappend.py '


# (name, file, [(old, new)], gate command, modes that must be red)
SPECS = [
 ('T1 no per-write seek: an append entry is a plain writer (solo, two, '
  'truncg, fork6, park5 red)', FD2,
  [("            bra   PRC_APPSEEK      ;append intent: seek to EOF\n",
    "            bra   PRC_OFT_REF\n")],
  KK + 'solo two truncg fork6 park5 exteof',
  ['solo', 'two', 'truncg', 'fork6', 'park5', 'exteof']),
 ('T2 admission counts an appender as a no-intent writer (order, two '
  'red)', F4,
  [("            and   #OFTF_AP\n            beq   :nowr\n",
    "            and   #0\n            beq   :nowr\n")],
  KK + 'order two', ['order', 'two']),
 ('T3 the append acquire loads the saved mark (PRC_ROACQ): $4D '
  '(truncg red)', FD2,
  [("PRC_APPSEEK\n            jsr   PRC_OFT_RES\n",
    "PRC_APPSEEK\n            jsr   PRC_OFT_REF\n")],
  KK + 'truncg', ['truncg']),
 ('T4 a reader counts appenders as writers (order red: the late '
  'reader)', F4,
  [(":rd         lda   PRC_VICT         ;reader: one no-intent writer\n",
    ":rd         lda   PRC_VICT\n            ora   PRC_LENDX\n")],
  KK + 'order', ['order']),
 ('T5 the per-write seek reaches the device paths (a9 red)', MLI3,
  [(":isnull     lda   PRC_PARM+MLI_REQLO\n",
    ":isnull     ldx   #1\n            jsr   PRC_APPSEEK\n"
    "            bcc   :isn1\n            rts\n"
    ":isn1       lda   PRC_PARM+MLI_REQLO\n")],
  KK + 'a9', ['a9']),
 ('T6 count 3 means append (abi red)', F4,
  [("            ldx   #OFTF_AP\n            cmp   #OPEN_APPEND\n",
    "            ldx   #OFTF_AP\n            cmp   #3\n")],
  KK + 'abi', ['abi']),
 ('T7 $A3 is not refused (abi red)', F4,
  [("            cmp   #OPEN_RO_APP\n            bne   :store\n",
    "            cmp   #OPEN_RO_APP\n            bra   :store\n")],
  KK + 'abi', ['abi']),
 ('T8 an appender ignores a no-intent writer (abi, order red)', F4,
  [("            lda   PRC_VICT         ;appender: no-intent count\n",
    "            lda   #0               ;appender: no-intent count\n")],
  KK + 'abi order', ['abi', 'order']),
 ('T9 a lone appender is named in K_ROOWN (solo red)', FD2,
  [("            and   #OFTF_MG\n            beq   :solo\n"
    "            stx   K_ROOWN\n",
    "            and   #OFTF_MG\n            nop\n            nop\n"
    "            stx   K_ROOWN\n")],
  KK + 'solo', ['solo']),
 ('T10 K_ROOWN is published BEFORE the seeks (fault red)', FD2,
  [("            phx                    ;the MLI calls clobber X\n",
    "            phx                    ;the MLI calls clobber X\n"
    "            stx   K_ROOWN\n")],
  KK + 'fault', ['fault']),
 ('T13 a park does not clear K_ROOWN: the acquire\'s unpark leaves a '
  'parked holder named (parkown red)', FD2,
  [("            cpx   K_ROOWN\n            bne   :unext\n"
    "            stz   K_ROOWN\n",
    "            cpx   K_ROOWN\n            bne   :unext\n"
    "            nop\n            nop\n")],
  KK + 'parkown', ['parkown']),
 ('T14 admission skips PARKED entries (OFT_IOBUF 0): a no-intent '
  'writer beside a parked group joins (parkadm red)', F4,
  [(":cnt        lda   OFT_PIPE,x\n            bmi   :nxt\n",
    ":cnt        lda   OFT_IOBUF,x\n            beq   :nxt\n"
    "            lda   OFT_PIPE,x\n            bmi   :nxt\n")],
  KK + 'parkadm', ['parkadm']),
 ('T15 a park ignores OFTF_PIN: a lone relative (pinned) entry is '
  'parked (relpin red)', FD2,
  [("            and   #OFTF_PIN            ;never a victim\n",
    "            and   #0                   ;never a victim\n")],
  KK + 'relpin', ['relpin']),
 ('T16 a RELATIVE open is stored without its identity, as before '
  '(rel red)', FD2,
  [("            lda   PRC_CANLEN       ;0: no identity, the copy\n",
    "            lda   PRC_PATHBUF+1    ;SABOTAGE: a RELATIVE open\n"
    "            cmp   #\"/\"+$80        ;keeps no identity\n"
    "            beq   :kpa\n            lda   #0\n            bra   :stl\n"
    ":kpa        lda   PRC_CANLEN\n:stl")],
  KK + 'rel', ['rel']),
 ('T17 admission skips unknown-identity entries only if parked: the '
  'fail-safe is gone (parkadm red)', F3,
  [("            beq   :busy          ;unless the open can SHARE it:\n",
    "            bne   :hvp\n            bra   :notpark\n"
    ":hvp                             ;unless the open can SHARE it:\n")],
  KK + 'parkadm', ['parkadm']),
 ('T18 no trailing-slash strip in the canonical identity: `G/` is not '
  'G (slash red)', FD2,
  [("            cmp   #\"/\"+$80\n            bne   :ok\n"
    "            dex\n            beq   :ok\n",
    "            cmp   #\"/\"+$80\n            bra   :ok\n"
    "            dex\n            beq   :ok\n")],
  KK + 'slash', ['slash']),
 ('T11 the GET_EOF carry is not checked (fault red)', FD2,
  [(":seek       jsr   PMLI_GTF_CALL\n            bne   :err\n",
    ":seek       jsr   PMLI_GTF_CALL\n            nop\n            nop\n")],
  KK + 'fault', ['fault']),
 ('T12 the SET_MARK carry is not checked (fault red)', FD2,
  [("            jsr   PMLI_SMARK_CL\n            bne   :err\n"
    "            plx\n",
    "            jsr   PMLI_SMARK_CL\n            nop\n            nop\n"
    "            plx\n")],
  KK + 'fault', ['fault']),
]


SHP = 'src/bin/shpath.s'
SHP2 = 'src/bin/shpth2.s'
SHELL = 'python3 scripts/check_oappend_sh.py '
CEN = 'python3 scripts/check_open_census.py'
CENF = 'scripts/open_census.txt'

SPECS += [
 ('S1 sh `>>` back to no intent (A1, A1e, A2 red)', SHP,
  [(SHP2, "SH_OPARM       dfb   OPEN_APPEND\n",
    "SH_OPARM       dfb   PCOUNT_OPEN\n"),
   (SHP, "            lda   #OPEN_APPEND           ;`>>` shares the parm:\n",
    "            lda   #PCOUNT_OPEN           ;`>>` shares the parm:\n")],
  SHELL + 'A1 A1e A2', ['A1', 'A1e', 'A2'], 'build/sh.bin'),
 ('S2 sh `>>` back to no intent: the census says append (census red)',
  SHP,
  [(SHP2, "SH_OPARM       dfb   OPEN_APPEND\n",
    "SH_OPARM       dfb   PCOUNT_OPEN\n"),
   (SHP, "            lda   #OPEN_APPEND           ;`>>` shares the parm:\n",
    "            lda   #PCOUNT_OPEN           ;`>>` shares the parm:\n")],
  CEN, ['src/bin/shpath.s'], 'build/sh.bin'),
 ('S3 tee -a back to no intent (A1t red)', 'src/bin/tee.s',
  [("OPARM       dfb   OPEN_APPEND\n", "OPARM       dfb   PCOUNT_OPEN\n")],
  SHELL + 'A1t', ['A1t'], 'build/tee.bin'),
 ('S4 tee -a back to no intent (census red)', 'src/bin/tee.s',
  [("OPARM       dfb   OPEN_APPEND\n", "OPARM       dfb   PCOUNT_OPEN\n")],
  CEN, ['src/bin/tee.s'], 'build/tee.bin'),
 ('S5 nohup.out back to no intent (A1n red)', 'src/bin/nohupfd.s',
  [("NH_OPARM       dfb   OPEN_APPEND\n",
    "NH_OPARM       dfb   PCOUNT_OPEN\n")],
  SHELL + 'A1n', ['A1n'], 'build/nohup.bin'),
 ('S6 nohup.out back to no intent (census red)', 'src/bin/nohupfd.s',
  [("NH_OPARM       dfb   OPEN_APPEND\n",
    "NH_OPARM       dfb   PCOUNT_OPEN\n")],
  CEN, ['src/bin/nohupfd.s'], 'build/nohup.bin'),
 ('S7 the census calls tee none (census red)', CENF,
  [("bin/tee.s OPARM append", "bin/tee.s OPARM none")],
  CEN, ['src/bin/tee.s'], None),
 ('S8 the census calls tail append (census red)', CENF,
  [("bin/tail.s OPARM ro", "bin/tail.s OPARM append")],
  CEN, ['src/bin/tail.s'], None),
 ('S9 admission: appenders count as no-intent writers (A1, A2 red)', F4,
  [("            and   #OFTF_AP\n            beq   :nowr\n",
    "            and   #0\n            beq   :nowr\n")],
  SHELL + 'A1 A2', ['A1', 'A2']),
 ('S10 no per-write seek (A1e red: two fds, two marks)', FD2,
  [("            bra   PRC_APPSEEK      ;append intent: seek to EOF\n",
    "            bra   PRC_OFT_REF\n")],
  SHELL + 'A1 A1e', ['A1', 'A1e']),
 ('S11 the seek reaches the device paths (A9 red)', MLI3,
  [(":isnull     lda   PRC_PARM+MLI_REQLO\n",
    ":isnull     ldx   #15\n            jsr   PRC_APPSEEK\n"
    "            bcc   :isn1\n            rts\n"
    ":isn1       lda   PRC_PARM+MLI_REQLO\n")],
  SHELL + 'A9', ['A9']),
 ('S13 ONLY sh\'s initializer back to count 3 (census red AND the '
  'first `>>` of a fresh shell is no-intent: A1 red)', SHP2,
  [("SH_OPARM       dfb   OPEN_APPEND\n",
    "SH_OPARM       dfb   PCOUNT_OPEN\n")],
  '(' + CEN + '; r1=$?; ' + SHELL + 'A1; r2=$?; exit $((r1+r2)))',
  ['src/bin/shpath.s', 'A1'], 'build/sh.bin'),
 ('S14 a relative open is stored without identity (A1x, A5x red)', FD2,
  [("            lda   PRC_CANLEN       ;0: no identity, the copy\n",
    "            lda   PRC_PATHBUF+1    ;SABOTAGE: a RELATIVE open\n"
    "            cmp   #\"/\"+$80        ;keeps no identity\n"
    "            beq   :kpa\n            lda   #0\n            bra   :stl\n"
    ":kpa        lda   PRC_CANLEN\n:stl")],
  SHELL + 'A1x A2x A5x', ['A1x', 'A2x', 'A5x']),
 ('S12 a no-intent open joins appenders (W4, A8 red)', F4,
  [("            ora   PRC_LENDX        ;no-intent: any writer\n",
    "                                   ;no-intent: any writer\n")],
  '(python3 scripts/check_openrw2.py W4; r1=$?; ' + SHELL +
  'A8; r2=$?; exit $((r1+r2)))', ['W4s', 'A8']),
]


#: the composite commands of S12/S13: each side with the rows it owns
COMPOSITE = {
    'S12': [('python3 scripts/check_openrw2.py W4', ['W4']),
            (SHELL + 'A8', ['A8'])],
    'S13': [(CEN, ['src/bin/shpath.s']), (SHELL + 'A1', ['A1'])],
}


def check(cmd, rows):
    if 'check_open_census' in cmd:
        return T.Check(cmd, 'bullets_only', T.Rows(red=rows, rule=T.ANY))
    return T.Check(cmd, 'tagged', T.Rows(red=rows))


def tooth(name, fn, edits, cmd, rows, art='build/MAUXPLAY.SYSTEM'):
    # an edit is (old, new) on `fn`, or (file, old, new)
    edits = [e if len(e) == 3 else (fn, e[0], e[1]) for e in edits]
    chks = [check(c, r) for c, r in COMPOSITE[name.split()[0]]] \
        if name.split()[0] in COMPOSITE else [check(cmd, rows)]
    if art is None:                      # the census file: nothing to build
        return T.Tooth(name, edits=edits, checks=chks, prep=T.NoBuild(),
                       artifacts=(), witness=T.SourceOnly())
    return T.Tooth(name, edits=edits, checks=chks, artifacts=[art])


T.main('oappend', [tooth(*s) for s in SPECS], match=T.TOKEN,
       prep=T.Make('play-image'), artifacts=['build/MAUXPLAY.SYSTEM'])
