#!/usr/bin/env python3
"""check_doctruth.py -- documented claims that were once false, held true.

WHY. Four claims were found contradicting the code on 2026-10-26 (DOC-TRUTH):
  1. docs/man/sh.1 said pipelines inside $( ) are refused; they work (the
     body goes to a nested sh since 2026-08-27).  Only nesting and an
     unclosed $( are refused.
  2. the prose said sh implements `set -x` only; the builtin's usage
     string is `set -x|+x|-e|+e`.  Asserted against docs/man/sh.1 since
     2026-11-02: the doc that carried the original stale claim is not
     published, and a gate must read what a reader can read.
  3. docs/ARCHITECTURE.md and docs/SUPPORT.md described a PROBED aux-bank
     free list; the release kernel fills a FIXED list (PRC_INIT), so maux
     needs >= 1 MB of aux RAM and runs at most 15 processes.
  4. src/kernel/timer.s called the Mockingboard tier "presence-only, no
     timer programmed"; TMR_INT_MB programs the 6522 T1.

Each check derives the TRUTH from the source (a literal, a string, a
compare) and requires the prose to agree.  Static, host-only, ~0.1 s.
`--selftest` plants the stale claim (or the code change that would make
the prose stale) in an in-memory copy and requires red; the real run
only passes if the selftest does.

NOT GATED, honestly: that a comment says anything TRUE about its code in
general.  Check 4 catches only the specific contradiction (a comment that
says no timer is programmed beside code that programs the 6522).  The
runtime half of claim 1 (`$(ls | wc -l)` works) is already gated by
check-play (typed case ECHO X$(ECHO P | CAT)Y) and check-shlang (OPP);
this gate pins that those rows still exist, and that SUB_GRAB still
refuses only what the man page says it refuses.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    'man': 'docs/man/sh.1',
    'arch': 'docs/ARCHITECTURE.md',
    'supp': 'docs/SUPPORT.md',
    'proc': 'src/kernel/process.s',
    'shblt': 'src/bin/shbltn.s',
    'shexp': 'src/bin/shexp2.s',
    'timer': 'src/kernel/timer.s',
    'play': 'scripts/check_play.py',
    'shlang': 'scripts/build_shlang_image.py',
}


def load():
    t = {}
    for k, p in FILES.items():
        with open(os.path.join(ROOT, p), encoding='ascii') as f:
            t[k] = f.read()
    t['src_nontest'] = nontest_probe_calls()
    return t


def nontest_probe_calls():
    """Files under src/ (outside src/test) that CALL BankProbe."""
    hits = []
    for d, _, fs in os.walk(os.path.join(ROOT, 'src')):
        rel = os.path.relpath(d, ROOT)
        if rel.startswith('src/test') or rel == 'src/test':
            continue
        for fn in fs:
            if not fn.endswith('.s'):
                continue
            with open(os.path.join(d, fn), encoding='latin-1') as f:
                for line in f:
                    if re.match(r'^\s+(jsr|jmp)\s+BankProbe\b', line,
                                re.I):
                        hits.append(os.path.join(rel, fn))
    return hits


def code_lines(text):
    """Source lines with comment-only lines dropped."""
    return [l for l in text.splitlines() if not l.startswith('*')]


# ---- 3: the fixed bank list -------------------------------------------
def bank_facts(proc):
    m = re.search(
        r'^PRC_INIT\b.*?lda\s+#(\d+)\s*\n\s*sta\s+PRC_FREE_CNT.*?'
        r'lda\s+#(\d+)\s*\n:freelp.*?cpx\s+#(\d+)', proc, re.S | re.M)
    if not m:
        return None
    cnt, top, cpx = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return dict(cnt=cnt, top=top, cpx=cpx, low=top - cnt + 1,
                procs=cnt + 1, mb=(top + 1) * 64 // 1024)


def check_banks(t):
    p = []
    f = bank_facts(t['proc'])
    if f is None:
        return ['process.s: PRC_INIT free-list shape not recognised '
                '(update check_doctruth.bank_facts)']
    if f['cpx'] != f['cnt']:
        p.append('process.s: PRC_FREE_CNT %d != loop bound %d'
                 % (f['cnt'], f['cpx']))
    want = ['banks %d-%d' % (f['low'], f['top']),
            'at most %d processes' % f['procs'],
            '%d MB' % f['mb']]
    for doc in ('arch', 'supp'):
        for w in want:
            if w not in t[doc]:
                p.append('%s: missing "%s" (PRC_INIT fills banks %d-%d)'
                         % (FILES[doc], w, f['low'], f['top']))
    if 'allocated from a probed free-list' in t['arch']:
        p.append('ARCHITECTURE.md: still says banks are "allocated from '
                 'a probed free-list"')
    if t['src_nontest']:
        p.append('BankProbe is now CALLED outside src/test (%s): the '
                 '"probe is unshipped" prose in ARCHITECTURE/SUPPORT is '
                 'stale' % ', '.join(t['src_nontest']))
    return p


# ---- 2: set builtin usage ---------------------------------------------
def check_set(t):
    p = []
    m = re.search(r'SETUSAGE_MSG\s+asc\s+"usage: set ([^"]+)"', t['shblt'])
    if not m:
        return ['shbltn.s: SETUSAGE_MSG not found']
    usage = m.group(1)
    flags = sorted(set(re.findall(r'[-+]([a-z])', usage)))
    if not flags:
        return ['shbltn.s: SETUSAGE_MSG has no flags']
    # The man page is the ONLY prose asserted against, and that is the
    # point of this version. It used to also require docs/SH-FEATURES.md
    # to quote the usage string verbatim -- then SH-FEATURES.md was
    # withheld from the published tree (2026-11-02), and this gate
    # CRASHED there with FileNotFoundError while passing in-house,
    # because the file is present in a real checkout and absent from
    # what gets published. A claim that lives only in an unpublished
    # document is a claim a reader cannot check, which is the house
    # rule this gate exists to enforce; sh.1 already documented all
    # four flags, so nothing was lost by moving the assertion to it.
    #
    # Both SIGNS are required, derived from the usage string rather
    # than matched as one literal: `set -x|+x` means the man page owes
    # a `set -x` AND a `set +x`, so dropping half the pair is red.
    for fl in flags:
        for sign in ('-', '+'):
            if 'set %s%s' % (sign, fl) not in t['man']:
                p.append('%s: no mention of `set %s%s`, which '
                         'SETUSAGE_MSG offers'
                         % (FILES['man'], sign, fl))
    return p


# ---- 1: $( ) and operators --------------------------------------------
def check_subst(t):
    p = []
    m = re.search(r'^SUB_GRAB\b.*?^:close', t['shexp'], re.S | re.M)
    if not m:
        return ['shexp2.s: SUB_GRAB not found']
    body = '\n'.join(code_lines(m.group(0)))
    cmps = sorted(set(re.findall(r'cmp\s+#(\$[0-9A-Fa-f]+)', body)))
    if cmps != ['$A8', '$A9']:
        p.append('shexp2.s SUB_GRAB compares %s; the man page claims '
                 'only "(" (nesting) and a missing ")" are refused -- '
                 'update both together' % cmps)
    para = re.search(r'\$\(command args\).*?\n\.PP', t['man'], re.S)
    if not para:
        return p + ['sh.1: the $(command args) paragraph is gone']
    txt = para.group(0)
    for sent in re.split(r'\.\s', txt):
        if re.search(r'\brefused\b', sent):
            for w in ('pipeline', 'redirection', 'list', 'background'):
                if w in sent:
                    p.append('sh.1: a "refused" sentence names "%s" -- '
                             'operators work inside $( ) (nested sh)' % w)
    if 'nest' not in txt:
        p.append('sh.1: $( ) paragraph no longer says nesting is refused')
    if 'one external command' in txt:
        p.append('sh.1: still says $( ) runs "one external command"')
    if 'ECHO X$(ECHO P | CAT)Y' not in t['play']:
        p.append('check_play.py: the pipe-inside-$( ) runtime row is gone')
    if 'ECHO $(CAT /mnt/MAUX/MGFILE | GREP CAT)' not in t['shlang']:
        p.append('build_shlang_image.py: the OPP pipe-in-$( ) row is gone')
    return p


# ---- 4: timer.s Mockingboard comment ----------------------------------
def check_timer(t):
    p = []
    m = re.search(r'^TMR_INT_MB\b.*?\n\s+rts', t['timer'], re.S | re.M)
    if not m:
        return ['timer.s: TMR_INT_MB not found']
    arms = re.search(r'sta\s+MB_T1CH', m.group(0)) is not None
    if arms:
        for i, l in enumerate(t['timer'].splitlines(), 1):
            if l.startswith('*') and re.search(
                    r'no\s+timer\s+programmed|Mockingboard-stub', l):
                p.append('timer.s:%d: comment says the Mockingboard tier '
                         'programs no timer, but TMR_INT_MB writes '
                         'MB_T1CH' % i)
    else:
        p.append('timer.s: TMR_INT_MB no longer arms T1 -- the '
                 'Mockingboard-tier prose needs a second look')
    return p


def run_checks(t):
    return (check_banks(t) + check_set(t) + check_subst(t)
            + check_timer(t))


def selftest(t):
    """Each mutation re-plants a stale claim; every one must go red."""
    def mut(key, old, new):
        assert old in t[key], (key, old)
        u = dict(t)
        u[key] = t[key].replace(old, new, 1)
        return u
    cases = []
    cases.append(('bank list grows to 15 entries (docs say 14)',
                  mut('proc', 'lda   #14\n            sta   PRC_FREE_CNT',
                      'lda   #15\n            sta   PRC_FREE_CNT')))
    cases.append(('bank list top moves to 7 (docs say 2-15)',
                  mut('proc', 'lda   #15\n:freelp', 'lda   #7\n:freelp')))
    cases.append(('arch reverts to probed free-list prose',
                  mut('arch', 'allocated from a FIXED free list',
                      'allocated from a probed free-list')))
    u = dict(t)
    u['src_nontest'] = ['src/kernel/boot.s']
    cases.append(('BankProbe called from the boot', u))
    cases.append(('support loses its process cap',
                  mut('supp', 'at most 15 processes', 'many processes')))
    cases.append(('set gains -u in the usage string',
                  mut('shblt', 'set -x|+x|-e|+e"',
                      'set -x|+x|-e|+e|-u|+u"')))
    cases.append(('sh.1 forgets set +x',
                  mut('man', 'set -x, set +x, set -e, set +e',
                      'set -x, set -e, set +e')))
    cases.append(('sh.1 forgets set -e',
                  mut('man', 'set -x, set +x, set -e, set +e',
                      'set -x, set +x')))
    cases.append(('sh.1 says pipelines refused again',
                  mut('man', 'The body is run by a nested sh, so pipelines, '
                      'redirections, lists and\nbackground operators inside '
                      'it mean what they say, as in\n$(ls | wc -l).',
                      'It is not a general subshell: pipelines, '
                      'redirections, lists and\nbackground operators inside '
                      'it are refused.')))
    cases.append(('SUB_GRAB starts refusing "|"',
                  mut('shexp', "cmp   #$A9                   ;')' high",
                      "cmp   #$FC\n            beq   :bad\n"
                      "            cmp   #$A9                   ;')' high")))
    cases.append(('timer comment says no timer programmed',
                  mut('timer', 'The REAL Mockingboard tier is NOT one of',
                      'Mockingboard: presence-only, no timer programmed, '
                      'NOT one of')))
    bad = 0
    for name, u in cases:
        got = run_checks(u)
        if not got:
            print('[check-doctruth] SELFTEST FAIL (stayed green): ' + name)
            bad += 1
        else:
            print('[check-doctruth] selftest ok (red): %s' % name)
    return bad


def main():
    t = load()
    bad = 0 if '--no-selftest' in sys.argv else selftest(t)
    if bad:
        print('[check-doctruth] FAIL: %d mutation(s) not caught' % bad)
        return 1
    if '--selftest-only' in sys.argv:
        return 0
    probs = run_checks(t)
    for x in probs:
        print('[check-doctruth] RED: ' + x)
    if probs:
        return 1
    print('[check-doctruth] PASS: bank list, set usage, $( ) operators, '
          'timer comment agree with the source')
    return 0


if __name__ == '__main__':
    sys.exit(main())
