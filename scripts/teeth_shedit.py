#!/usr/bin/env python3
"""teeth_shedit.py -- the sabotage runner behind check-shedit's teeth
(docs/TAB-A2-NOTES.md sec 12), on scripts/teeth_lib.py (HYG-4). NOT a
gate and in no sweep: it edits src/bin/shedit*.s / shlex2.s / sh.s and
the kernel, rebuilds the play image, runs the named check_shedit.py
case (or a check-jobctl gate) on one backend and requires it RED on the
tooth's own row, with the sabotaged build DIFFERING from the good one.
It restores from the captured bytes (never `git checkout`) and the final
rebuild must reproduce the good artifacts. See teeth_lib.py for the
exit status (0 all behaved, 1 a tooth did not bite, 2 runner broken).

  python3 scripts/teeth_shedit.py            # all
  python3 scripts/teeth_shedit.py S3 S8a     # by name prefix
  python3 scripts/teeth_shedit.py --dry      # static pattern lint
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import teeth_lib as T  # noqa: E402

SPECS = [
 ('S1 modes: ED_COOK never restores', 'modes', 'src/bin/shedit.s',
  [("ED_COOK     lda   ED_RAWF", "ED_COOK     lda   #0")]),
 ('S2 typeahead: first byte of every read dropped', 'typeahead', 'src/bin/shedit.s',
  [(":bytes      stz   ED_BI", ":bytes      lda   #1\n            sta   ED_BI")]),
 ('S3 intr_mid: no missing newlines after ^C', 'intr_mid', 'src/bin/shedit.s',
  [("ED_INTRNL   lda   ED_CUR", "ED_INTRNL   jmp   ED_FLUSH\n            lda   ED_CUR")]),
 ('S4 stop: TSTP left at default around the read', 'stop', 'src/bin/shedit.s',
  [("            lda   #SIG_TSTP\n            ldx   #SIGA_CATCH\n            jsr   SC_SIGNAL\n            sta   ED_PTSTP",
    "            lda   #SIG_TSTP\n            ldx   #SIGA_DFL\n            jsr   SC_SIGNAL\n            sta   ED_PTSTP")]),
 ('S5 eof: ^D never ends the shell', 'eof', 'src/bin/shedit.s',
  [("ED_DEL      lda   ED_LEN\n            beq   :eof", "ED_DEL      lda   #1\n            beq   :eof")]),
 ('S6 switch: console not raw while the editor owns the line', 'switch', 'src/bin/shedit.s',
  [("            ldx   #TMD_OPOST\n            jsr   SC_TTYMODE         ;raw, no echo, OPOST kept", "            ldx   #7\n            jsr   SC_TTYMODE         ;raw, no echo, OPOST kept")]),
 ('S7 noraw: editor runs for non-interactive readers too', 'noraw', None,
  [('src/bin/shedit.s', "            lda   SH_INTERACT\n            beq   :out\n            lda   SH_NOEDIT", "            lda   SH_NOEDIT"),
   ('src/bin/shlex2.s', "            lda   CUR_IN_FD\n            bne   :nedit\n            jsr   ED_LINE", "            jsr   ED_LINE")]),
 ('S8a hist: ring not cleared at START (warm respawn / nested)', 'hist', 'src/bin/shedit.s',
  [("ED_INIT     stz   SH_EDIT\n            stz   ED_HN\n", "ED_INIT     stz   SH_EDIT\n")]),
 ('S8b hist: ninth entry kept (limit 9)', 'hist', 'src/bin/shedit2.s',
  [(":chk        lda   ED_HN\n            cmp   #8\n            bcs   :ev", ":chk        lda   ED_HN\n            cmp   #9\n            bcs   :ev")]),
 ('S8c hist: no stash of the line in progress', 'hist', 'src/bin/shedit2.s',
  [(":sd         lda   ED_LEN\n            sta   ED_STASH\n", ":sd         lda   ED_LEN\n")]),
 ('S9 trap_int: popped INT not parked for PUMP_TRAP', 'trap_int', 'src/bin/shedit.s',
  [(":hold       jsr   SIG_PARK", ":hold       clc\n            nop\n            nop\n            ;")]),
 ('S10 cap: 200-char line', 'cap', 'src/bin/sh.s',
  [("ED_LENMAX   equ   127", "ED_LENMAX   equ   200")]),
 ('S11 column: prompt moved to a fresh row', 'column', 'src/bin/shedit.s',
  [("            stz   ED_PRM\n            lda   ED_PCH\n            jsr   ED_OUTB\n",
    "            stz   ED_PRM\n            lda   #$8D\n            nop\n            jsr   ED_OUTB\n")]),
 ('S13 bgjob: a SELF set walks the declarer\'s subtree (no exact-match test)', 'bgjob', 'src/kernel/procspawn2.s',
  [("            bit   PRC_FG_SET             ;count bit 7: SELF set\n            bmi   :no                    ;exact members only\n", "")]),
 ('S13b tcsub: same kernel sabotage, the ABI row', 'cmd:make check-jobctl-b', 'src/kernel/procspawn2.s',
  [("            bit   PRC_FG_SET             ;count bit 7: SELF set\n            bmi   :no                    ;exact members only\n", "")]),
 ('S14 esc_cr: ESC [ Return cooks the console with the line open', 'esc_cr', 'src/bin/shedit.s',
  [("            cmp   #2                 ;line open, still raw", "            cmp   #9                 ;line open, still raw")]),
 ('S15 clear: ^L does not clear the screen', 'clear', 'src/bin/shedit.s',
  [("ED_CLR      dfb   $9B,$DB,$C8,$9B,$DB,$B2,$CA", "ED_CLR      dfb   $9B,$DB,$C8,$9B,$DB,$B2,$CB")]),
 ('S16 tcnone: any pid accepted by TCSETFG', 'cmd:make check-jobctl-b', 'src/kernel/procspawn2.s',
  [(":child      sta   P_PID\n", ":child      bra   :nx\n            sta   P_PID\n")]),
 ('S17 tcclr: {0} does not clear the set', 'cmd:make check-jobctl-b', 'src/kernel/procspawn2.s',
  [(":store      lda   PTF_CON\n", ":store      lda   PTF_PID\n            bne   :real\n            jmp   PRC_RET_OK0\n:real       lda   PTF_CON\n")]),
 ('S18 tcself: the caller itself refused', 'cmd:make check-jobctl-b', 'src/kernel/procspawn2.s',
  [("            bne   :child\n            lda   #$80", "            bra   :child\n            lda   #$80")]),
 ('S21 tcchild: the child path falls into the SELF flag (found by check-jobctl-a script_whole)', 'cmd:make check-jobctl-b', 'src/kernel/procspawn2.s',
  [(":child      sta   P_PID\n", ":child      lda   #$80\n            tsb   PRC_PARM+0\n            lda   PRC_PARM+1,x\n            sta   P_PID\n")]),
 ('S21b tcchild-a: same plant, the script_whole row', 'cmd:make check-jobctl-a', 'src/kernel/procspawn2.s',
  [(":child      sta   P_PID\n", ":child      lda   #$80\n            tsb   PRC_PARM+0\n            lda   PRC_PARM+1,x\n            sta   P_PID\n")]),
 ('S22 term: a TERM interrupts the line like ^C', 'term', 'src/bin/shedit.s',
  [("            cmp   #SIG_TSTP\n            bne   :hold\n:int", "            cmp   #SIG_TSTP\n            nop\n            nop\n:int")]),
 ('S23 term: ERR_INTR is end of file (the shell exits on a TERM)', 'term', 'src/bin/shedit.s',
  [(":rerr       cmp   #ERR_INTR\n            bne   :eof\n", ":rerr       cmp   #ERR_INTR\n            bra   :eof\n")]),
 ('S24 kill9: the tty backstop does nothing', 'kill9', 'src/kernel/procspawn2.s',
  [("PRC_TMD_RST\n            sta   P_PID\n", "PRC_TMD_RST\n            rts\n            sta   P_PID\n")]),
 ('S25 noecho: the editor paints under stty -echo', 'cmd:make check-jobctl-a', 'src/bin/shedit.s',
  [("            and   #TMD_ECHO          ;stty -echo: nothing may\n            bne   :fgok", "            and   #TMD_ECHO          ;stty -echo: nothing may\n            bra   :fgok")]),
 ('S26 trapnow: a trapped TERM waits for Return at an empty prompt', 'cmd:make check-jobctl-a', 'src/bin/shedit.s',
  [("            stx   ED_INTR            ;finished first\n", "            nop\n            nop\n            nop\n")]),
 ('S27 termtrap: a trapped TERM interrupts the typed line', 'termtrap', 'src/bin/shedit.s',
  [("            bne   :next              ;open); a typed line is\n", "            nop\n            nop\n")]),
 ('S28 termcons: a trapped TERM ends the read inside a construct', 'termtrap', 'src/bin/shedit.s',
  [("            ora   CSPTR              ;the trap NOW (no construct\n", "            nop\n            nop\n            nop\n")]),
 ('S13c stopjob: SELF set walks the subtree (stopped-job half alone)', 'stopjob', 'src/kernel/procspawn2.s',
  [("            bit   PRC_FG_SET             ;count bit 7: SELF set\n            bmi   :no                    ;exact members only\n", "")]),
 ('S19 wrap80: the editor believes half the columns (40 on an 80-column glass; lsr leaves carry clear)', 'text80:parity', 'src/bin/shedit.s',
  [("            lda   ED_GEOBUF\n            sta   ED_W\n", "            lda   ED_GEOBUF\n            lsr   a\n            sta   ED_W\n")]),
 ('S20 wraput: same, on the UltraTerm', 'ut:parity', 'src/bin/shedit.s',
  [("            lda   ED_GEOBUF\n            sta   ED_W\n", "            lda   ED_GEOBUF\n            lsr   a\n            sta   ED_W\n")]),
 ('S12 parity: ^A and ^E swapped', 'parity', 'src/bin/shedit.s',
  [("ED_VECS     da    ED_HOME,ED_LEFT,ED_DEL,ED_END", "ED_VECS     da    ED_END,ED_LEFT,ED_DEL,ED_HOME")]),
]


JC_A = 'make check-jobctl-a'


def tooth(name, case, f, edits):
    """(name, case, file, [(old, new)]) -> a Tooth. `case` is
    `[backend:]case` for check_shedit.py, or `cmd:make check-jobctl-x`."""
    if f is not None:
        edits = [(f, a, b) for a, b in edits]
    if case.startswith('cmd:'):
        cmd = case[4:]
        if cmd == JC_A:
            chk = T.Check(cmd, 'jobctl', T.Rows(red=JOBCTL_A_ROWS[name.split()[0]]))
        else:
            chk = T.Check(cmd, 'aggregate', T.Aggregate(
                JOBCTL_B_PRED[name.split()[0]], 'check-jobctl-b stops at its first '
                'failed assertion and prints no row id'))
    else:
        bk, _, cs = case.rpartition(':')
        bk = bk or 'text40'
        chk = T.Check('python3 scripts/check_shedit.py %s %s' % (bk, cs),
                      'namerows', T.Rows(red=['%s [%s]' % (cs, bk)]))
    return T.Tooth(name, edits=edits, checks=[chk],
                   retired=RETIRED.get(name.split()[0], ''))


#: teeth that no longer run: listed, not deleted (Tooth.retired, with the
#: reason). Empty since S13c was un-retired when check_shedit `stopjob`
#: got a pace-independent barrier (docs/HYG-4-NOTES.md 10.2).
RETIRED = {}

#: check-jobctl-a rows each tooth must turn red (observed, then read
#: against the tooth's intent)
JOBCTL_A_ROWS = {
    'S21b': ['script_whole'],       # the script_whole row of the tcchild plant
    'S25': ['shell_nested'],        # a nested sh keeps echo off
    'S26': ['shell_term'],          # a trapped TERM waits for Return
}
#: the first-failure text check-jobctl-b prints for each tooth
JOBCTL_B_PRED = {
    'S13b': r'^\[check-jobctl-b\] FAIL: tcsub: the child is ZOMBIE after',
    'S16': r'^\[check-jobctl-b\] FAIL: tcsetfg a non-child non-self pid is '
           r'refused, set untouched: rc=\$00',
    'S17': r'^\[check-jobctl-b\] FAIL: tcsetfg \{0\} clears \(flag too\): '
           r'declared set',
    'S18': r'^\[check-jobctl-b\] FAIL: tcsetfg self is accepted: rc=\$E1',
    'S21': r'^\[check-jobctl-b\] FAIL: stop: the declared set .* of a CHILD '
           r'carries the SELF flag',
}

T.main('shedit', [tooth(*s) for s in SPECS],
       prep=T.Make('play-image'),
       # split_kseg.py writes MAUXPLAY.SYSTEM and its .full together: both
       # are deleted so make runs that recipe (the kernel edits land in
       # the cold segment, i.e. only in .full)
       artifacts=['build/sh.bin', 'build/MAUXPLAY.SYSTEM',
                  'build/MAUXPLAY.SYSTEM.full'])
