#!/usr/bin/env python3
"""check_openrw2.py -- a reader and a writer hold one file at once, as
the shell sees it (`make check-openrw2`, docs/OPEN-RW-2.md,
docs/OPEN-RW-2-NOTES.md).

Boots the play image and types each row at the shell, the
check_openrw.py idiom (its helpers are imported).  The kernel-side
rows (slot orders, truncation under a reader, close ownership, park,
fork and dup, spawn, identity, K_ROOWN) are scripts/check_openrw2_k.py.

THE DEFECT.  ProDOS refuses a second OPEN of an open file ($50) and
maux inherited that, then OPEN-RO-2 let several READ-INTENT opens share
one refnum.  A writer carries no intent, so a reader next to a long
writer (`tail -f LOG` beside `cmd >> LOG &`) and a writer next to a long
reader (`exec 4<LOG; echo x >> LOG`) were both $50.  Now ONE no-intent
open may join the group.

Phase K rows (sh's `<` already declares read intent):
  W1  `exec 3>>LOG`, then `cat <LOG` prints LOG; `echo m >&3` and
      `cat <LOG` shows `m` (the writer's live EOF, in-group).  The same
      across a 512-byte block boundary.
  W3  `exec 4<LOG`, one line read (mark nonzero), `echo x >> LOG`
      succeeds with sh's retry counter at 0, and the NEXT read gets the
      SECOND line (the reader's mark survived the writer's turn).
  W4s a second NO-INTENT writer (`>`) next to a writer+reader group is
      still refused after OPEN-RW-1's bound; a third reader joins
      either way round.  OAPPEND-1 converted this row: the second
      writer used to be `>>`, which now joins (W4a).

  W2  the idiom (needs tail to declare read intent): a background
      appender writes a numbered line a second through ONE long-held
      `>> LOG`, and `tail -f LOG` in the foreground shows every line,
      in order, while the appender runs.

ASCII only.  Exit 0 green, 1 red (listed), 2 rig problem.
"""
import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_openrw as W  # noqa: E402
import check_devfs as D  # noqa: E402
import gate_race as GR  # noqa: E402
import arena  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT = ['W1', 'W2', 'W3', 'W4']


def run(rig, line, label, failures, **kw):
    out, _ = W.run_line(rig, line, label, failures, **kw)
    return out


def fx(rig, lines, failures):
    return W.fixture_lines(rig, lines, failures)


def eq(label, got, want, failures):
    if got != want:
        failures.append(f'{label}: got {got!r}, want {want!r}')


def seen(rig):
    return max(rig.seen().values(), default=0)


# 42 bytes: two 20-char lines.  Eleven of them are 462 bytes, so two
# appends of eleven cross the 512-byte block boundary of LOG.
LINE = '01234567890123456789'
CAT11 = 'cat L L L L L L L L L L L >&3'


def row_w1(rig, failures):
    lab = 'W1'
    fx(rig, ['echo a > LOG', 'exec 3>>LOG'], failures)
    eq(f'{lab}: cat <LOG beside the writer', run(rig, 'cat <LOG', lab,
       failures), ['a'], failures)
    run(rig, 'echo m >&3', lab, failures)
    eq(f'{lab}: after echo m >&3 (live EOF)', run(rig, 'cat <LOG', lab,
       failures), ['a', 'm'], failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: after the writer closed', run(rig, 'cat LOG', lab,
       failures), ['a', 'm'], failures)
    # across a 512-byte block boundary, interleaved
    fx(rig, [f'echo {LINE} > L', f'echo {LINE} >> L', 'echo a > LOG',
             'exec 3>>LOG'], failures)
    run(rig, CAT11, lab, failures)
    eq(f'{lab}: 464 bytes in the first block', run(rig, 'cat <LOG | wc -c',
       lab, failures), ['464'], failures)
    run(rig, CAT11, lab, failures)
    eq(f'{lab}: 926 bytes across the boundary', run(rig,
       'cat <LOG | wc -c', lab, failures), ['926'], failures)
    run(rig, 'echo z >&3', lab, failures)
    eq(f'{lab}: and the tail', run(rig, 'cat <LOG | tail -n 1', lab,
       failures), ['z'], failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: closed, byte count', run(rig, 'wc -c LOG', lab, failures),
       ['928 LOG'], failures)
    # reader FIRST: the writer JOINS an existing read group and must
    # still be able to write (a joiner must not inherit OFTF_RO)
    fx(rig, ['echo a > LOG', 'exec 4<LOG', 'exec 3>>LOG'], failures)
    eq(f'{lab}: a writer joining a reader writes', run(rig,
       'echo m >&3', lab, failures), [], failures)
    eq(f'{lab}: and the reader sees it', run(rig, 'cat <&4', lab,
       failures), ['a', 'm'], failures)
    run(rig, 'exec 3>&- 4<&-', lab, failures)


def row_w3(rig, failures):
    lab = 'W3'
    fx(rig, ['echo a > LOG', 'echo b >> LOG', 'echo c >> LOG',
             'exec 4<LOG'], failures)
    eq(f'{lab}: first read', run(rig, 'read A <&4; echo $A', lab,
       failures), ['a'], failures)
    rig.clear_seen()
    out = run(rig, 'echo x >> LOG', lab, failures)
    eq(f'{lab}: echo x >> LOG beside a long reader', out, [], failures)
    eq(f'{lab}: retry counter (no retry needed)', seen(rig), 0, failures)
    eq(f'{lab}: the reader resumes at its mark', run(rig,
       'read B <&4; echo $B', lab, failures), ['b'], failures)
    run(rig, 'exec 4<&-', lab, failures)
    eq(f'{lab}: LOG', run(rig, 'cat LOG', lab, failures),
       ['a', 'b', 'c', 'x'], failures)


def row_w4(rig, failures):
    """OAPPEND-1 CONVERSION (authorised, docs/OAPPEND-1.md "Changed
    expectation"): this row asserted that a second `>>` is refused.
    `>>` is an APPEND open now and joins, so the second writer that
    stays refused is a deliberate NO-INTENT open: `echo x > LOG` is
    creat, count 3, and is refused BEFORE its truncating SET_EOF.  Both
    slot orders keep the mixed-group shape (writer+reader first, reader
    +writer first); each is run with the first writer an APPENDER and
    with it NO-INTENT (`exec 3>LOG`, so two non-append writers stay
    exclusive).  A sibling row (W4a) has the second writer as `>>`: it
    joins."""
    lab = 'W4s'
    for first, mk in (('appender', ['echo a > LOG', 'exec 3>>LOG',
                                    'exec 4<LOG']),
                      ('no-intent', ['exec 3>LOG', 'echo a >&3',
                                     'exec 4<LOG'])):
        # writer first, then a reader, then a second writer: refused
        fx(rig, mk, failures)
        rig.clear_seen()
        out = run(rig, 'echo x > LOG', lab, failures, q=20_000)
        eq(f'{lab}: second (no-intent) writer, {first} first', out,
           ['sh: cannot redirect'], failures)
        eq(f'{lab}: ... after the bound', seen(rig), W.OW_MAX, failures)
        eq(f'{lab}: a third reader still joins', run(rig, 'cat <LOG', lab,
           failures), ['a'], failures)
        run(rig, 'exec 3>&- 4<&-', lab, failures)
        # reader first, then a writer, then a second writer: refused
        fx(rig, ['echo a > LOG', 'exec 4<LOG',
                 'exec 3>>LOG' if first == 'appender' else 'exec 3>LOG'],
           failures)
        if first == 'no-intent':
            run(rig, 'echo a >&3', lab, failures)
        rig.clear_seen()
        out = run(rig, 'echo x > LOG', lab, failures, q=20_000)
        eq(f'{lab}: second (no-intent) writer, reader then {first}', out,
           ['sh: cannot redirect'], failures)
        eq(f'{lab}: a third reader still joins', run(rig, 'cat <LOG', lab,
           failures), ['a'], failures)
        run(rig, 'exec 3>&- 4<&-', lab, failures)
        eq(f'{lab}: LOG untouched by the refusals', run(rig, 'cat LOG',
           lab, failures), ['a'], failures)
    # W4a: the sibling -- the second writer is `>>` and JOINS
    lab = 'W4a'
    fx(rig, ['echo a > LOG', 'exec 3>>LOG', 'exec 4<LOG'], failures)
    rig.clear_seen()
    eq(f'{lab}: a second `>>` joins an appender+reader group',
       run(rig, 'echo x >> LOG', lab, failures), [], failures)
    eq(f'{lab}: ... without a retry', seen(rig), 0, failures)
    run(rig, 'exec 3>&-', lab, failures)
    eq(f'{lab}: the reader sees it', run(rig, 'cat <&4', lab, failures),
       ['a', 'x'], failures)
    run(rig, 'exec 4<&-', lab, failures)


def row_w2(rig, failures):
    """The idiom.  LOG is padded to 504 bytes, then a background
    appender writes a numbered line a second through ONE long-held
    `>> LOG`, so LOG crosses its 512-byte block boundary while the
    appender runs.  `tail -f LOG` in the foreground must show every
    line, in order, while the appender runs: all of them by the time
    two of tail's polls (2 s) have passed after the appender's last
    write (its end marker is on the glass, raised on stderr AFTER the
    last line was written)."""
    lab = 'W2'
    secs = 7
    lines = [f'echo {LINE} > L', f'echo {LINE} >> L',
             'cat L L L L L L > LOG', 'cat L L L L L L >> LOG']
    # the appender: its STDOUT is the long-held writer (`>> LOG`)
    for n in range(1, secs + 1):
        lines.append('echo "sleep 1" >> W')
        lines.append(f'echo "echo L{n}" >> W')
    lines.append('echo "echo W-END >&2" >> W')
    fx(rig, lines, failures)
    W.run_line(rig, 'sh W >> LOG &', lab, failures)
    anchor = '$ tail -f LOG #W2'
    rig.type('tail -f LOG #W2\r')
    want = [f'L{n}' for n in range(1, secs + 1)]
    end_at = None
    shown = None
    for _ in GR.polls(rig.c, 3000, 50_000):
        reg = W.below(rig.rows(), anchor)
        if reg is None:
            continue
        rows = [r for r in reg if r != 'W-END']
        if end_at is None and 'W-END' in reg:
            end_at = 0
        if end_at is not None:
            end_at += GR.quantum(50_000)
        if rows[-len(want):] == want and end_at is not None:
            shown = rows
            break
        if end_at is not None and end_at > 2_200_000:
            shown = rows
            break
    rig.type('\x03')
    try:
        D.wait_for_screen(rig.c, D.prompt_ready, lab, max_steps=400)
    except RuntimeError:
        W.recover(rig)
    if shown is None:
        failures.append(f'{lab}: tail -f never showed the appender end; '
                        f'glass below the command: '
                        f'{W.below(rig.rows(), anchor)!r}')
        return
    eq(f'{lab}: tail -f showed every line, in order, within two polls '
       f'of the last write', shown[-len(want):], want, failures)
    out = cat_log = run(rig, 'wc -c LOG', lab, failures)
    size = int((out or ['0'])[0].split()[0])
    eq(f'{lab}: LOG crossed its 512-byte block', size > 512, True,
       failures)


ROWS = {'W1': row_w1, 'W3': row_w3, 'W4': row_w4, 'W2': row_w2}


def boot(play, tmp):
    return W.boot(play, tmp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--play', default=os.path.join(ROOT, 'build',
                                                   'play.po'))
    ap.add_argument('rows', nargs='*', help='W1 W2 W3 W4 (default all)')
    args = ap.parse_args()
    play = os.path.abspath(args.play)
    if not os.path.exists(play):
        print(f'check-openrw2: {play} missing -- make play-image')
        return 2
    want = args.rows or DEFAULT
    syms = arena.symbol_table('sh')
    failures = []
    t0 = time.time()
    for tag in want:
        tmp = tempfile.mkdtemp(prefix='maux-openrw2-')
        try:
            client = boot(play, tmp)
            try:
                rig = W.Rig(client, syms)
                W.fixture_lines(rig, ['cd /tmp'], failures)
                n0 = len(failures)
                try:
                    ROWS[tag](rig, failures)
                except RuntimeError as exc:
                    failures.append(f'{tag}: {exc}')
                print(f'[check-openrw2] {tag}: '
                      f'{"PASS" if len(failures) == n0 else "FAIL"}',
                      flush=True)
            finally:
                client.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print(f'[check-openrw2] FAIL: {len(failures)} problem(s)')
        for x in failures:
            print(f'  - {x}'.replace('\n', '\n    '))
        return 1
    print(f'[check-openrw2] PASS ({time.time() - t0:.0f} s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
