#!/usr/bin/env python3
"""check_kledger.py -- the kernel ledger gate (docs/KLEDGER.md).

HOST-SIDE: no emulator.  It reads the merlin32 -v1 listings and the
built `.SYSTEM` files that the image-building gates already left in
build/, so like check-kernel-images it measures built artifacts and is
placed AFTER the image builders in CHECK_ALL_TARGETS.

  (a) EXHAUSTIVENESS over every kernel listing present in build/: the
      attributed bytes equal the image's size ON DISK (and, for the play
      image, its _KSEG and _LSEG siblings), the listing's object bytes
      equal the bytes on disk, and no row is unplaced.  The contract is
      scripts/kledger.py's header.
  (b) FRESHNESS of docs/KLEDGER-TABLE.md: it must equal a fresh
      generation for MAUXPLAY, so the committed ledger cannot go stale.
      A kernel change regenerates it with `make kledger` and the diff
      rides in the commit.  The play image must not itself be stale
      against its source closure (check_kernel_images.check_staleness),
      or the comparison would bless an old listing.
  (c) TEETH: every run first proves the gate can fail.  On a scratch
      copy of the smallest image it plants (1) a row of unknown Line
      Type, (2) a sized row with an unknown mnemonic, (3) one extra byte
      on the `.SYSTEM`, (4) one byte short, (5) one flipped byte, and
      (6) a tampered table and (7) a missing one -- each must be
      refused -- after a clean control passes.  (6) and (7) run the
      real run_table() on scratch files (KFIX2 item 2: they used to
      compare a string with an edited copy of itself).

Usage: check_kledger.py            run (a), (b) and (c)
       check_kledger.py --selftest (c) only
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kledger as K  # noqa: E402

ROOT = K.ROOT
BUILD = K.BUILD
SCRATCH = os.path.join(BUILD, 'kledger_selftest')
FIXTURE = 'MAUXNM.SYSTEM'          # the smallest kernel image
PLAY = 'MAUXPLAY.SYSTEM'


def diff_text(want, got):
    """None when equal, else a one-line description of the first
    difference."""
    if want == got:
        return None
    a, b = want.split('\n'), got.split('\n')
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else '<end of file>'
        y = b[i] if i < len(b) else '<end of file>'
        if x != y:
            return 'line %d: committed %r, fresh %r' % (i + 1, y[:70],
                                                        x[:70])
    return 'differs'


def check_one(name, build=BUILD):
    """-> (ledger or None, problems)."""
    try:
        led = K.build_ledger(K.listing_path(name, build))
    except K.LedgerError as e:
        return None, e.problems
    except OSError as e:
        return None, [str(e)]
    return led, K.verify(led, build)


def run_exhaustive():
    fails = []
    names = K.all_images(BUILD)
    if not names:
        return ['no kernel listing in build/ -- build the images first'], 0
    for n in names:
        _, probs = check_one(n)
        for p in probs[:10]:
            fails.append('%s: %s' % (n, p))
    return fails, len(names)


def play_is_fresh():
    """Staleness of the play image against its put/use closure."""
    import check_manifests as cm
    import check_kernel_images as cki
    graph, _ = cm.build_graph()
    images, _ = cki.derive_kernel_images(graph)
    keep = {m: {t for t in ts if os.path.basename(t) == PLAY}
            for m, ts in images.items()}
    keep = {m: ts for m, ts in keep.items() if ts}
    return cki.check_staleness(graph, keep)


def run_table(table=K.TABLE, led=None):
    """Problems with the committed ledger `table` (a path) against a
    fresh MAUXPLAY generation; [] when it is current.  `led` is that
    generation if the caller already built it (the selftest builds it
    once and runs this three times).  The path is a PARAMETER so the
    selftest can run THIS function on a tampered copy and a missing
    path; it used to read K.TABLE directly and the selftest compared a
    string with an edited copy of itself instead (KFIX2 item 2)."""
    if led is None:
        led, probs = check_one(PLAY)
        if led is None or probs:
            return ['%s: cannot build the ledger: %s' % (PLAY, probs[:3])]
    name = os.path.relpath(table, ROOT) if table == K.TABLE else table
    if not os.path.exists(table):
        return ['%s is missing -- run `make kledger`' % name]
    with open(table, encoding='ascii') as fh:
        have = fh.read()
    d = diff_text(K.fmt_table(led), have)
    if d:
        return ['%s is stale (%s) -- run `make kledger` and commit '
                'the diff' % (name, d)]
    return []


def plant(src_listing, dst, edit):
    with open(src_listing, encoding='ascii', errors='replace') as fh:
        text = fh.read().split('\n')
    edit(text)
    with open(dst, 'w', encoding='ascii') as fh:
        fh.write('\n'.join(text))


def first_row(text, ltype, mnem=None):
    for i, ln in enumerate(text):
        f = ln.split('|', 7)
        if len(f) == 8 and f[2].strip() == ltype and (
                mnem is None or mnem in f[7].split()[:2]):
            return i
    raise RuntimeError('selftest: no %s row' % ltype)


def run_selftest():
    """-> list of failures (an expectation that did not hold)."""
    fails = []
    if os.path.isdir(SCRATCH):
        shutil.rmtree(SCRATCH)
    os.makedirs(SCRATCH)
    try:
        src_sys = os.path.join(BUILD, FIXTURE)
        src_lst = src_sys + '_Output.txt'
        if not (os.path.exists(src_sys) and os.path.exists(src_lst)):
            return ['teeth need build/%s and its listing' % FIXTURE]
        dst_sys = os.path.join(SCRATCH, FIXTURE)
        dst_lst = dst_sys + '_Output.txt'

        def fresh():
            shutil.copyfile(src_sys, dst_sys)
            shutil.copyfile(src_lst, dst_lst)

        def expect(label, red, probs):
            ok = bool(probs) == red
            print('  %-44s %s' % (label, (
                'red as required: ' + probs[0][:60] if probs and red
                else 'green' if not probs else 'RED UNEXPECTEDLY')))
            if not ok:
                fails.append('selftest %s: expected %s, got %s' % (
                    label, 'red' if red else 'green',
                    probs[:1] or 'green'))

        fresh()
        _, p = check_one(FIXTURE, SCRATCH)
        expect('control (untouched copy)', False, p)

        fresh()

        def bad_type(t):
            i = first_row(t, 'Code')
            f = t[i].split('|', 7)
            f[2] = ' Frobnicate  '
            t[i] = '|'.join(f)
        plant(src_lst, dst_lst, bad_type)
        _, p = check_one(FIXTURE, SCRATCH)
        expect('planted unknown Line Type', True, p)

        fresh()

        def bad_mnem(t):
            i = first_row(t, 'Data', 'dfb')
            t[i] = t[i].replace('dfb', 'zzz', 1)
        plant(src_lst, dst_lst, bad_mnem)
        _, p = check_one(FIXTURE, SCRATCH)
        expect('planted unknown data mnemonic', True, p)

        fresh()
        with open(dst_sys, 'ab') as fh:
            fh.write(b'\0')
        _, p = check_one(FIXTURE, SCRATCH)
        expect('file one byte longer than the listing', True, p)

        fresh()
        with open(dst_sys, 'r+b') as fh:
            fh.truncate(os.path.getsize(dst_sys) - 1)
        _, p = check_one(FIXTURE, SCRATCH)
        expect('file one byte shorter than the listing', True, p)

        fresh()
        with open(dst_sys, 'r+b') as fh:
            fh.seek(100)
            b = fh.read(1)
            fh.seek(100)
            fh.write(bytes([b[0] ^ 0xFF]))
        _, p = check_one(FIXTURE, SCRATCH)
        expect('one flipped byte (stale / wrong listing)', True, p)

        # the committed-table check, run for real on scratch files: a
        # copy of the FRESH generation (so a stale committed table
        # cannot colour the control) passes, a tampered copy and a
        # missing path both fail
        led, p = check_one(PLAY, BUILD)
        if led is None or p:
            return fails + ['teeth need build/%s and its listing: %s'
                            % (PLAY, p[:1])]
        table = K.fmt_table(led)
        good = os.path.join(SCRATCH, 'KLEDGER-TABLE.md')
        tam = os.path.join(SCRATCH, 'KLEDGER-TABLE.tampered.md')
        with open(good, 'w', encoding='ascii') as fh:
            fh.write(table)
        with open(tam, 'w', encoding='ascii') as fh:
            fh.write(table.replace('| code |', '| c0de |', 1))
        if table == table.replace('| code |', '| c0de |', 1):
            fails.append('selftest: the tamper edit changed nothing')
        expect('untampered table', False, run_table(good, led))
        expect('tampered table', True, run_table(tam, led))
        expect('missing table', True,
               run_table(os.path.join(SCRATCH, 'absent.md'), led))
    finally:
        shutil.rmtree(SCRATCH, ignore_errors=True)
    return fails


def main(argv):
    os.chdir(ROOT)
    print('[check-kledger] teeth')
    fails = run_selftest()
    if '--selftest' not in argv:
        print('[check-kledger] exhaustiveness over every kernel listing')
        f, n = run_exhaustive()
        fails += f
        print('   %d listing(s) checked' % n)
        print('[check-kledger] docs/KLEDGER-TABLE.md vs a fresh %s '
              'generation' % PLAY)
        fails += list(play_is_fresh())
        fails += run_table()
    if fails:
        for f in fails:
            print('[check-kledger] FAIL: ' + f, file=sys.stderr)
        return 1
    print('[check-kledger] PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
