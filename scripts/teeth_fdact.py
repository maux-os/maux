#!/usr/bin/env python3
"""teeth_fdact.py -- sabotage run for check-fdact (docs/DUPFD-1.md
"Teeth, sabotage each separately", phase K), on scripts/teeth_lib.py
(HYG-4).

For each planted defect: rewrite the kernel source, wait out GNU make
3.81's whole-second mtimes, rebuild build/fdatest.po (and the plain twin
build/fdatestp.po), assert the harness image's bytes DIFFER from the
baseline's, run scripts/check_fdact.py and require it RED on a ROW
(`B0 ..`, `K6 ..`): check_fdact prints environment failures (`<disk>
not found`, `mount_disk`, `the guest never reached handshake N`) on the
same `FAIL:` channel as a verdict, so the assertion is a row-shaped
failure line, which those cannot satisfy. Sources are restored from the
captured bytes and the final rebuild must reproduce both images. Exit
status: teeth_lib.py (0 all behaved, 1 a tooth did not bite, 2 runner
broken).

  python3 scripts/teeth_fdact.py [substring of a sabotage name ...]
  python3 scripts/teeth_fdact.py --dry
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

K = 'src/kernel'
FILES = {'pf2': K + '/procfile2.s', 'p2': K + '/process2.s'}

TOP = ('p2', ':parmsok    jsr   PRC_FDA_CHECK\n            bcc   :fdaok\n',
       ':parmsok    clc\n            nop\n            nop\n'
       '            bcc   :fdaok\n')

# sabotages whose red must show on the PLAIN twin (fdatestp, spawnpl.s)
# too: the ones the bad lists alone can see
ON_PLAIN = ('validation removed', 'source range', 'target range',
            'unknown opcode', 'walk unbounded', 'read carry')

# (name, [(file key, old, new)...], what it breaks)
SABOTAGES = [
    ('validation removed (K1, K7 red)',
     [TOP],
     'every bad list spawns; the replay trusts what it is given'),
    ('source range check removed (K2 red)',
     [('pf2', '            lda   P_FD\n            cmp   #8\n'
       '            bcs   :bad\n            lda   K_CURPID\n',
       '            lda   P_FD\n            cmp   #8\n'
       '            nop\n            nop\n            lda   K_CURPID\n')],
     'fd 8 / $FF as a source reads the poisoned PCB bytes: "open"'),
    ('target range check removed (K2 red)',
     [('pf2', ':tgt        lda   P_TMP\n            cmp   #8\n'
       '            bcs   :bad\n',
       ':tgt        lda   P_TMP\n            cmp   #8\n'
       '            nop\n            nop\n')],
     'fd 8 / $FF as a target is replayed into the child PCB'),
    ('unknown opcode ends the list (K3 red)',
     [('pf2', '            bne   :bad                 ;an opcode we do not'
       ' have\n',
       '            bne   :good                ;an opcode we do not'
       ' have\n')],
     'opcode 3 / $FF is a clean END, as the old replay had it'),
    ('walk unbounded (K3 red)',
     [('pf2', '            cmp   #99                  ;32 records + END'
       ' slot\n            bcc   :loop\n',
       '            bra   :loop\n            nop\n            nop\n')],
     'a list with no END wraps its 8-bit index and never ends'),
    ('read carry ignored (K3 red)',
     [('pf2', '            jsr   PRDPAR_BYTE          ;BYTE=opcode,'
       ' +1=target\n            bcs   :out\n',
       '            jsr   PRDPAR_BYTE          ;BYTE=opcode,'
       ' +1=target\n            nop\n            nop\n')],
     'an unreadable list is judged by the stale PRC_BYTE'),
    ('CLOSE source byte judged (K6 red)',
     [('pf2', '            cmp   #FDACT_DUP\n            bne   :done        '
       '        ;not a DUP: no source\n',
       '            cmp   #FDACT_END\n            beq   :done        '
       '        ;not a DUP: no source\n'),
      ('pf2', '            cmp   #FDACT_CLOSE\n            beq   :tgt\n'
       '            cmp   #FDACT_DUP\n            bne   :bad ',
       '            cmp   #FDACT_CLOSE\n            bne   :nclo\n'
       '            lda   P_FD\n            cmp   #8\n'
       '            bcs   :bad\n            bra   :tgt\n'
       ':nclo       cmp   #FDACT_DUP\n            bne   :bad ')],
     'a CLOSE with the reserved byte $FF is refused'),
    ('validation after LZ_WANT_SET (K5 red)',
     [TOP,
      ('p2', ':haveimg    jsr   PRC_ALLC_BANK\n',
       ':haveimg    jsr   PRC_FDA_CHECK\n            bcc   :fdaok2\n'
       '            rts\n:fdaok2     jsr   PRC_ALLC_BANK\n')],
     'a file spawn that fails leaves the one-shot LZ_WANT armed'),
    ('validation after PRC_ALLC_BANK (K5 red)',
     [TOP,
      ('p2', ':bankok     sta   PRC_CHLD_BANK\n',
       ':bankok     pha\n            jsr   PRC_FDA_CHECK\n'
       '            bcc   :fdaok3\n            pla\n            rts\n'
       ':fdaok3     pla\n            sta   PRC_CHLD_BANK\n')],
     'a failed spawn keeps the bank it allocated'),
    ('validate as you replay (K4, K5 red)',
     [TOP,
      ('p2', '            jsr   PRC_FDACTIONS\n\n            lda   '
       'PRC_CHILD_PID\n',
       '            jsr   PRC_FDACTIONS\n            bcc   :fdaok4\n'
       '            lda   PRC_CHLD_BANK\n            jsr   PRC_FREE_BANK\n'
       '            sec\n            rts\n:fdaok4\n\n            lda   '
       'PRC_CHILD_PID\n'),
      ('pf2', ':have       stz   P_IDX\n:loop       jsr   PRC_FDA_REC\n'
       '            cmp   #FDACT_DUP\n            beq   :dup\n',
       ':have       stz   P_IDX\n            bra   :loop\n'
       ':sabfail    lda   #ERR_INVAL\n            jsr   PRC_FAIL_A\n'
       '            sec\n            rts\n:sabend     clc\n            rts\n'
       ':loop       jsr   PRC_FDA_REC\n            bcs   :sabfail\n'
       '            cmp   #FDACT_END\n            beq   :sabend\n'
       '            cmp   #FDACT_CLOSE\n            beq   :sabtgt\n'
       '            cmp   #FDACT_DUP\n            bne   :sabfail\n'
       '            lda   P_FD\n            cmp   #8\n'
       '            bcs   :sabfail\n            lda   PRC_PAR_PID\n'
       '            sta   P_PID\n            jsr   PRC_GET_FDOBJ\n'
       '            beq   :sabfail\n:sabtgt     lda   P_TMP\n'
       '            cmp   #8\n            bcs   :sabfail\n'
       '            jsr   PRC_FDA_REC\n            cmp   #FDACT_DUP\n'
       '            beq   :dup\n'),
      ('pf2', '            bne   :have\n            rts\n',
       '            bne   :have\n            clc\n            rts\n'),
      ('pf2', '            adc   #3\n            sta   P_IDX\n'
       '            bra   :loop\n',
       '            adc   #3\n            sta   P_IDX\n'
       '            cmp   #99\n            bcc   :loop\n'
       '            bra   :sabfail\n')],
     'record 1 of a list is applied before record 2 is judged bad'),
    ('PRC_PAR_PID read, not K_CURPID (K6 red)',
     [('pf2', '            lda   K_CURPID\n            sta   P_PID\n'
       '            jsr   PRC_GET_FDOBJ\n            beq   :bad ',
       '            lda   PRC_PAR_PID\n            sta   P_PID\n'
       '            jsr   PRC_GET_FDOBJ\n            beq   :bad ')],
     'the caller is taken to be the stale pid the gate poked'),
]


#: a failing CHECK row (not an environment failure): `B0  DUP 4<-5 ..`,
#: `K6 P0 DUP 5<-3 ..`, `K5 LZ_WANT is clear`
ROW = r'^\[check-fdact\] FAIL: (B[0-9]+|K[0-9]+) '
WHY = ('check-fdact prints one PASS/FAIL line per check, with no row ids '
       'and no summary line')


def kids(name):
    """The check families a title names: `(K1, K7 red)` -> K1, K7. K7 is
    the errno-row family of the same report as K1..K4 and prints under
    those labels, so it cannot be asserted on its own (notes 9.2)."""
    m = re.search(r'\(([K0-9, ]+) red\)', name)
    return [k for k in re.findall(r'K[0-9]+', m.group(1))
            if k != 'K7'] if m else []


def kpred(k):
    """A failing row of check family `k`: either the row starts with it
    (`K5 LZ_WANT is clear`) or names it later (`B0 DUP .. K1 [builtin ..]`)."""
    return (r'^\[check-fdact\] FAIL: (?:%s |(?:B[0-9]+|K[0-9]+) .*\b%s\b)'
            % (k, k))


def tooth(name, edits, what):
    # one check per family the title names (the gate is re-run for each:
    # a few seconds), or the generic row-shaped failure if it names none
    chk = [T.Check('python3 scripts/check_fdact.py build/fdatest.po',
                   'fdact', T.Aggregate(kpred(k), WHY)) for k in kids(name)]
    chk = chk or [T.Check('python3 scripts/check_fdact.py build/fdatest.po',
                          'fdact', T.Aggregate(ROW, WHY))]
    if any(name.startswith(n) for n in ON_PLAIN):
        chk.append(T.Check(
            'python3 scripts/check_fdact.py build/fdatestp.po --plain',
            'fdact', T.Aggregate(ROW, WHY)))
    return T.Tooth(name, edits=[(FILES[k], o, n) for k, o, n in edits],
                   checks=chk, witness=T.Changed(quant=T.ALL)
                   if any(c.inv.text().endswith('--plain') for c in chk)
                   else None)


T.main('fdact', [tooth(*s) for s in SABOTAGES], match=T.SUBSTRING,
       prep=T.Make('build/fdatest.po', 'build/fdatestp.po'),
       artifacts=['build/fdatest.bin', 'build/fdatestp.bin'])
