"""hostoracle -- what a gate does when its HOST oracle is not installed.

A gate whose reference is a program on the host (vim for check-tip-vim,
nulib2 for check-nulib2 and check-floppy) used to print "SKIP" and exit
0 when the program was absent. Outside a sweep that is reasonable: a
laptop without vim can still `make check-x` the rest. In a sweep it is a
silent green -- the gate "passed" without checking anything, and
nothing says which host lacked the oracle (nulib2 sat missing from the
box that way from the day check-nulib2 landed until check-ls died on it;
vim kept check-tip-vim off the box list until HYG-1, 2026-10-20).

THE RULE: a sweep is a claim that every gate ran. Both sweep drivers
(the Makefile's check-all* loops and scripts/sweep_par.sh) export
MAUX_SWEEP=1, and under it a missing oracle is a FAILURE, with the
SKIP wording kept so the log says what was missing. It is decided HERE,
in the gate, and not by grepping logs for "SKIP" afterwards: logs carry
unrelated words (check-unpack prints "SKIP THE INTRODUCTION", check-fowler
counts skipped corpus rows) and a text match would be red on those and
green on the next gate that spells it differently.
"""
import os
import sys


def in_sweep():
    return os.environ.get('MAUX_SWEEP') == '1'


def skip(gate, why, fails=None):
    """Report a missing host oracle; return the exit status it earns.

    `fails`, when the gate collects failures in a list, gets the
    sweep-time failure appended so the gate's own summary shows it.
    """
    print(f'[{gate}] SKIP: {why}', flush=True)
    if not in_sweep():
        return 0
    msg = f'{why} -- a SKIP is red in a sweep (MAUX_SWEEP=1)'
    if fails is not None:
        fails.append(msg)
    else:
        print(f'[{gate}] FAIL: {msg}', file=sys.stderr, flush=True)
    return 1
