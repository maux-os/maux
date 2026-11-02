#!/usr/bin/env python3
"""teeth_dupfd_sh.py -- sabotage run for the S rows of check-shfd
(docs/DUPFD-1.md "Teeth", phase S), on scripts/teeth_lib.py (HYG-4).

For each planted defect: rewrite the sh source, wait out GNU make 3.81's
whole-second mtimes, rebuild build/play.po, assert build/sh.bin DIFFERS
from the baseline's, run `check_shfd.py --rows S` and require the tooth's
own S rows RED (or, for the one EQUIV tooth, the gate still GREEN: the
sabotage names a backstop that a second defence covers). Sources are
restored from the captured bytes and the final rebuild must reproduce
sh.bin. Exit status: teeth_lib.py (0 all behaved, 1 a tooth did not bite,
2 runner broken).

  python3 scripts/teeth_dupfd_sh.py [substring of a sabotage name ...]
  python3 scripts/teeth_dupfd_sh.py --dry
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

B = 'src/bin'
FILES = {'blt2': B + '/shblt2.s', 'path': B + '/shpath.s',
         'sub2': B + '/shsub2.s'}

# the two DUP_CHECK calls, each replaced by a `clc` the same length
RUN_CALL = ('blt2', 'RUN_PIPELINE\n            jsr   DUP_CHECK  ',
            'RUN_PIPELINE\n            clc\n            nop\n            nop'
            '  ')
GRP_CALL = ('sub2', 'SUB_GROUP   jsr   DUP_CHECK  ',
            'SUB_GROUP   clc\n            nop\n            nop  ')
# DUP_CHECK stops following a close
NOCLOSE = ('blt2', ':close      ldy   DUPTGT\n            lda   TGT_BIT,y\n'
           '            eor   #$FF\n            and   DCHELD\n',
           ':close      ldy   DUPTGT\n            lda   TGT_BIT,y\n'
           '            eor   #$FF\n            ora   DCHELD\n')
# EMIT_DUPS skips a closed source again (the pre-DUPFD-1 behaviour)
SKIP = ('path', '            beq   :badsrc                ;source already'
        ' closed\n',
        '            beq   :next                  ;source already'
        ' closed\n')

# (name, edits, expectation, what it breaks); expectation RED or EQUIV
SABOTAGES = [
    ('sh check removed (S2 red even with phase K)',
     [RUN_CALL, GRP_CALL], 'RED',
     'the pipe takes fd 3, the kernel sees it open, cat reads the pipe'),
    ('group check removed alone (S3c red)',
     [GRP_CALL], 'RED',
     'the group reaches the kernel; its answer carries no fd number'),
    ('close not followed (S3e red)',
     [NOCLOSE], 'RED',
     'DUP_CHECK lets `3>&- 0<&3` through; the backstop still refuses, '
     'but with a second message'),
    ('EMIT_DUPS skip restored + close not followed (S3e red)',
     [SKIP, NOCLOSE], 'RED',
     '`cat 3>&- 0<&3` reads the inherited fd 0 and exits 0'),
    ('EMIT_DUPS skip restored alone (backstop: stays green)',
     [SKIP], 'EQUIV',
     'DUP_CHECK already refused every list that reaches EMIT_DUPS'),
    ('dup / FILE target not marked held (S4c, S4d red)',
     [('blt2', ':set        ldy   DUPTGT\n            lda   TGT_BIT,y\n'
       '            ora   DCHELD\n',
       ':set        ldy   DUPTGT\n            lda   TGT_BIT,y\n'
       '            and   DCHELD\n')], 'RED',
     'a fd a record just opened is judged closed: good lists refused'),
    ('first file redirect not marked held (S4e red)',
     [('blt2', '            ldy   CMD_TGTFD,x            ;the file\'s fd\n'
       '            lda   TGT_BIT,y\n            ora   DCHELD\n',
       '            ldy   CMD_TGTFD,x            ;the file\'s fd\n'
       '            lda   TGT_BIT,y\n            and   DCHELD\n')], 'RED',
     '`cat 4>oG 1>&4` is refused: the stage\'s own `>` fd is not held'),
    ('ERR_INVAL mapped to command not found (S5 red)',
     [('blt2', ':einval     lda   DUPN\n            bne   :badfdk\n',
       ':einval     lda   DUPN\n            bra   :nobadfdk\n'
       ':nobadfdk\n')], 'RED',
     'a kernel-refused list prints `sh: command not found`'),
    ('group ERR_INVAL mapped to command not found (S5b red)',
     [('sub2', '            beq   :gnf                   ;  load base, as'
       ' ever)\n',
       '            bra   :gnf                   ;  load base, as'
       ' ever)\n')], 'RED',
     'a kernel-refused group prints `sh: command not found`'),
]


#: the S rows each tooth must turn red (the "(S2 red)" of its title: the
#: rows check-shfd already prints). The EQUIV tooth keeps S3e green.
ROWS = [['S2'], ['S3c'], ['S3e'], ['S3e'], ['S3e'], ['S4c', 'S4d'],
        ['S4e'], ['S5'], ['S5b']]
GATE = 'python3 scripts/check_shfd.py --rows S'


def tooth(sab, rows):
    name, edits, expect, what = sab
    edits = [(FILES[k], o, n) for k, o, n in edits]
    if expect == 'EQUIV':
        return T.Tooth(name, edits=edits, outcome=T.GREEN_EQUIVALENT,
                       checks=[T.Check(GATE, 'devfs', T.Rows(
                           controls=['S3e']))])
    return T.Tooth(name, edits=edits,
                   checks=[T.Check(GATE, 'devfs', T.Rows(red=rows))])


T.main('dupfd_sh', [tooth(s, r) for s, r in zip(SABOTAGES, ROWS)],
       match=T.SUBSTRING, prep=T.Make('play-image'),
       artifacts=['build/sh.bin'])
