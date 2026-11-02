#!/usr/bin/env python3
"""teeth_tabcomp.py -- the sabotage runner behind check-tabcomp's teeth
(docs/TAB-A3-NOTES.md), on scripts/teeth_lib.py (HYG-4). NOT a gate and
in no sweep: it edits src/bin/shtabc.s / shedit.s / shpth2.s / shlex.s,
rebuilds the play image, runs ONE check_tabcomp.py group on text40 and
requires it RED on that group's row, with the sabotaged sh.bin DIFFERING
from the good one. It restores from the captured bytes (never `git
checkout`) and the final rebuild must reproduce the good sh.bin. See
teeth_lib.py for the exit status (0 all behaved, 1 a tooth did not bite,
2 runner broken).

  python3 scripts/teeth_tabcomp.py            # all
  python3 scripts/teeth_tabcomp.py T2 T4      # by name prefix
  python3 scripts/teeth_tabcomp.py --dry      # static pattern lint
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

TC = 'src/bin/shtabc.s'
ED = 'src/bin/shedit.s'
GL = 'src/bin/shpth2.s'
LX = 'src/bin/shlex.s'


SPECS = [
 ('T1 no-op TAB binding: every completion row', 'cmd', ED,
  [("            dfb   $09\n", "            dfb   $00\n")]),
 ('T2 ED_KEY no longer shifts ED_NOPROG: `ca` TAB ^B ^F TAB lists',
  'cmd', ED, [("            lsr   ED_NOPROG          ;TAB TAB: see TC_TAB\n", "")]),
 ('T3 scan truncated at 31: AAA*/AB `A` TAB inserts `AA`', 'big', TC,
  [(":new        lda   TC_CNT\n",
    ":new        lda   TC_N\n            cmp   #MAXGLOB\n"
    "            bcs   :dup\n            lda   TC_CNT\n")]),
 ('T4 directory property ignored: /mnt/MAUX/ and DEMO/', 'path', TC,
  [("TC_ISDIR    txa\n", "TC_ISDIR    clc\n            rts\n            txa\n")]),
 ('T5 dedup removed: builtin + PATH echo, PATH twice', 'cmd', TC,
  [(":dd         cpx   TC_N\n            bcs   :new\n", ":dd         jmp   :new\n")]),
 ('T6 alias compare folds case: `z` offers Zed', 'cmd', TC,
  [("TC_SALIAS   stz   TC_FOLDF\n", "TC_SALIAS   lda   #$80\n            sta   TC_FOLDF\n")]),
 ('T7 cursor-position rule removed: mid-word completes', 'cursor', TC,
  [("            cmp   #ALC_A9\n            bne   :nop\n", "            cmp   #ALC_A9\n            nop\n            nop\n")]),
 ('T8 tail-blank rule removed: a second blank before the tail',
  'cursor', TC,
  [("            cpy   #ALC_A0\n            bne   :suf\n", "            cpy   #ALC_A0\n            bra   :suf\n")]),
 ('T9 glob characters not refused: `cat DEM*` grows `/`', 'refuse', TC,
  [("            dfb   TCC_STAR,TCC_QM,ALC_DB,ALC_BD",
    "            dfb   ALC_A7,TCC_QM,ALC_DB,ALC_BD")]),
 ('T10 redirect operand state dropped: `> out ca` is an argument',
  'path', TC, [(":rset       sta   TC_RP\n", ":rset       lda   #0\n            sta   TC_RP\n")]),
 ('T11 an assignment-shaped word refuses again: `A=1 ca` lists nothing',
  'cmd', TC,
  [("            bcs   :adv               ;a prefix assignment:\n", "            bcs   :rf                ;a prefix assignment:\n")]),
 ('T12 `case` does not refuse: `case X in A|ca` lists', 'refuse', TC,
  [("            inc   TC_CASE\n", "            nop\n            nop\n            nop\n")]),
 ('T13 fd operand not refused: `x 2>&` lists', 'refuse', TC,
  [("            cmp   #2\n            beq   :refuse\n            sta   TC_MODE", "            cmp   #2\n            nop\n            nop\n            sta   TC_MODE")]),
 ('T14 all-or-none cap removed: half of `O/` inserted', 'cursor', TC,
  [("            cmp   #ED_LENMAX+1\n            bcs   :no\n", "            cmp   #ED_LENMAX+1\n            nop\n            nop\n")]),
 ('T15 devices counted as directories: `/` after tty', 'path', TC,
  [("            and   #$0D\n            cmp   #$0D\n", "            and   #$0D\n            cmp   #$08\n")]),
 ('T16 `./` prefix not resolved: PATH=. offers nothing', 'path', GL,
  [("            cmp   #$2E             ;wants the dots resolved\n            bne   :opendir ", "            cmp   #$2E             ;wants the dots resolved\n            bra   :opendir ")]),
 ('T17 the second TAB never lists',
  'cmd', TC,
  [(":nopro      lda   TC_WAS\n            cmp   #1\n            bne   :arm\n", ":nopro      lda   TC_WAS\n            cmp   #1\n            bra   :arm\n            nop\n")]),
 ('T18 a stray store into the unowned LC above segment 1: the poison row',
  'lcfree', TC,
  [("TC_TAB      lda   ED_NOPROG          ;ED_KEY has shifted it: 1\n",
    "TC_TAB      stz   $FEFC\n            lda   ED_NOPROG          ;ED_KEY has shifted it: 1\n")]),
 ('T19 START no longer clears TC_ON: a poisoned cell eats a glob word',
  'lcfree', LX,
  [("            stz   TC_ON                  ;arena: not zeroed\n", "")]),
]


def tooth(name, group, fn, edits):
    return T.Tooth(name, edits=[(fn, a, b) for a, b in edits], checks=[
        T.Check('python3 scripts/check_tabcomp.py text40 ' + group,
                'namerows', T.Rows(red=['%s [text40]' % group]))])


T.main('tabcomp', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'), artifacts=['build/sh.bin'])
