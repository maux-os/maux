#!/usr/bin/env python3
"""Teeth for the harness itself, entirely on the host -- no emulator.

docs/E2E.md exists because four shipped programs had passing gates. The
lesson generalises to the gate: on 2026-08-22 `check-string` passed 21/21
against the very bug it targeted, because materialising each expectation
clobbered the register holding the verdict. **Assume a comparator is
vacuous until shown otherwise.**

So before the corpus is ever run on a IIe, every comparator here is shown
to have teeth:

  1. SYNTHESISE what a correct maux would have emitted, by pushing the
     host reference's output through the inverse of each divergence
     entry's transform and encoding it as high-bit maux text.
  2. Assert the comparator ACCEPTS it.  A comparator that rejects a
     correct answer is a false-failure machine.
  3. MUTATE it -- one byte flipped, one line dropped, one line
     duplicated, one high bit cleared -- and assert the comparator
     REJECTS every mutant.  A comparator that accepts a corrupted answer
     is the check-string failure again.

The synthesiser is NOT an oracle and is never used by the gate: it is an
authored model of maux's output format, which is exactly the kind of
thing docs/E2E.md sec 4 forbids as an expectation.  Its only job is to
give the mutation test something correct to corrupt.
"""
import copy
import math
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_compare as C      # noqa: E402
import e2e_divergence as D   # noqa: E402
from e2e_corpus import CASES, FIXTURES, Ref, SUM_BLOCKSZ, write_host_corpus  # noqa: E402

ENC = C.encode_maux_text


def _lines(data):
    return D._lines(data)


def _join(lines):
    return b''.join(ln + b'\n' for ln in lines)


def synth(case, ref_out, ref_err, ref_extra, hostdir):
    """(stdout, stderr) a correct maux would have written."""
    k = case.compare

    if k == 'exact':
        return ENC(ref_out), b''

    if k == 'wc_fields':
        lines = _lines(ref_out)
        if ('wc', 'totals saturate at 65535') in case.diverges:
            lines = D.wc_saturate(lines)
        return ENC(_join([b' '.join(ln.split()) for ln in lines])), b''

    if k == 'uniq_count':
        out = []
        for ln in _lines(ref_out):
            m = D._UNIQC_RE.match(ln)
            n, text = int(m.group(1)), m.group(2)
            out.append(str(n).rjust(5).encode() + b' ' + text)
        return ENC(_join(out)), b''

    if k == 'comm_cols':
        suppressed = {int(ch) for f in case.mflags for ch in f.lstrip('-')}
        unsup = [c for c in (1, 2, 3) if c not in suppressed]
        out = []
        for ln in _lines(ref_out):
            k2 = 0
            while ln[k2:k2 + 1] == b'\t':
                k2 += 1
            out.append(b'\t' * (unsup[k2] - 1) + ln[k2:])
        return ENC(_join(out)), b''

    if k == 'diff_nonewline':
        kept = [ln for ln in _lines(ref_out)
                if not ln.startswith(b'\\ No newline')]
        return ENC(_join(kept)), b''

    if k == 'grep_linemax':
        lines = [ln[:D.GREP_LINEMAX] for ln in _lines(ref_out)]
        return ENC(_join(lines)), b''


    if k == 'grep_open_continue':
        miss = [f'/mnt/MAUX/E2E/{o.name}'.encode()
                for o in case.operands
                if o.__class__.__name__ == 'Missing']
        assert len(miss) == 1, miss
        diag = b'grep: cannot open ' + miss[0] + b'\n'
        payload = [ln for ln in _lines(ref_out)
                   if not (ln.startswith(b'grep: ') and miss[0] in ln)]
        return ENC(diag + _join(payload)), b''

    if k == 'tee_open_continue':
        miss = [f'/mnt/MAUX/E2E/{o.name}'.encode()
                for o in case.operands
                if o.__class__.__name__ == 'Missing']
        assert len(miss) == 1, miss
        diag = b'tee: cannot open ' + miss[0] + b'\n'
        payload = [ln for ln in _lines(ref_out)
                   if not (ln.startswith(b'tee: ') and miss[0] in ln)]
        return ENC(diag + _join(payload)), b''

    if k == 'head_open_continue':
        miss = [f'/mnt/MAUX/E2E/{o.name}'.encode()
                for o in case.operands
                if o.__class__.__name__ == 'Missing']
        assert len(miss) == 1, miss
        diag = b'head: cannot open ' + miss[0] + b'\n'
        payload = [ln for ln in _lines(ref_out)
                   if not (ln.startswith(b'head: ') and miss[0] in ln)]
        return ENC(diag + _join(payload)), b''

    if k == 'cut_open_continue':
        miss = [f'/mnt/MAUX/E2E/{o.name}'.encode()
                for o in case.operands
                if o.__class__.__name__ == 'Missing']
        assert len(miss) == 1, miss
        diag = b'cut: cannot open ' + miss[0] + b'\n'
        payload = [ln for ln in _lines(ref_out)
                   if not (ln.startswith(b'cut: ') and miss[0] in ln)]
        return ENC(diag + _join(payload)), b''

    if k == 'tee_self_output':
        assert len(case.operands) == 1 and case.stdin is not None
        assert case.operands[0].name == case.stdin.name
        return ENC(b''), b''

    if k == 'echo_literal':
        return ENC(' '.join(case.operands).encode() + b'\n'), b''

    if k == 'tail_noeol':
        want = ref_out if ref_out.endswith(b'\n') else ref_out + b'\n'
        return ENC(want), b''

    if k == 'od_rows':
        is_c = '-c' in ''.join(case.mflags)
        sets = []
        for data in [ref_out] + list(ref_extra):
            rows, err = D._od_rows(data, 8, 'ref')
            assert rows is not None, err
            sets.append(rows)
        if not sets[0]:
            rows = [(0, [])]
        elif len(sets) == 1:
            rows = sets[0]
        else:
            bodies = [s[:-1] for s in sets]
            rows = [r for group in zip(*bodies) for r in group]
            rows.append(sets[0][-1])
        out = []
        for off, fields in rows:
            if is_c:
                fields, err = D._od_c_map(fields)
                assert fields is not None, err
            else:
                fields = [f.upper() for f in fields]
            out.append(f'{off:04X}'.encode()
                       + b''.join(b' ' + f for f in fields))
        return ENC(_join(out)), b''

    if k == 'sum_row':
        operands = [o for o in case.operands if isinstance(o, Ref)]
        out = []
        for i, ln in enumerate(_lines(ref_out)):
            m = D._SUM_RE.match(ln)
            ck, name = int(m.group(1)), m.group(3) or b''
            src = operands[i].name if operands else case.stdin.name
            blocks = math.ceil(os.path.getsize(
                os.path.join(hostdir, src)) / SUM_BLOCKSZ)
            row = f'{ck:05d} {blocks}'.encode()
            if name:
                row += b' ' + name
            out.append(row)
        return ENC(_join(out)), b''

    if k == 'sh_pid_pair':
        # A correct maux prints its own pid twice.  The VALUE cannot be
        # derived from the reference -- that is the whole reason this
        # comparator exists (see the ('sh', 'a pid VALUE...') divergence
        # entry) -- so stand in a plausible one: a bank number that is
        # non-zero and inside the usable range.  What the selftest is
        # proving here is that the comparator ACCEPTS a well-formed maux
        # answer; the mutation pass below proves it rejects malformed
        # ones, including the all-zeros shape the BANK_ID bug produced.
        return ENC(b'3 3'), b''

    if k == 'sh_closed_fd':
        # maux's own answer here is DETERMINISTIC, not a stand-in like
        # sh_pid_pair's (see the ('sh', 'a closed-stdin error code...')
        # divergence entry: cat/wc/od's shared REFILL idiom folds a
        # read ERROR into the same branch as EOF, so $? is always 0).
        return ENC(b'0'), b''

    if k == 'cmp_msg':
        return ENC(ref_out + ref_err), b''

    if k == 'printf_numerr':
        # A correct maux's OWN diagnostic wording is not the
        # reference's -- that is the whole point of this comparator --
        # so stand in a plausible one; the mutation pass below proves
        # the comparator rejects a malformed answer regardless.
        diag = b'printf: nonnumeric: expected numeric value\n'
        return ENC(diag + ref_out), b''

    raise AssertionError(f'no synthesiser for compare={k!r}')


# ----------------------------------------------------------------------
# Mutations.  Each returns (name, new_stdout, new_stderr) or None when it
# does not apply to that shape of output.
# ----------------------------------------------------------------------
def _mutants(case, out, err):
    """Corruptions a working comparator must reject.

    NOTE ON STDERR.  Every case runs `> Onn 2>&1`, so there is one
    stream, and a spurious diagnostic is just spurious output -- covered
    by the mutants below without a separate stderr channel.
    """
    target, is_err = (err, True) if (not out and err) else (out, False)
    muts = []

    def pack(data):
        return (out, data) if is_err else (data, err)

    if target:
        b = bytearray(target)
        i = len(b) - 2 if len(b) >= 2 else 0
        b[i] ^= 0x01
        muts.append(('flip one bit', *pack(bytes(b))))

        b = bytearray(target)
        b[len(b) // 2] &= 0x7F
        muts.append(('clear one high bit', *pack(bytes(b))))

        lines = target.split(b'\x8d')
        if len(lines) > 2:
            muts.append(('drop a line',
                         *pack(b'\x8d'.join(lines[:-2] + lines[-1:]))))
            muts.append(('duplicate a line',
                         *pack(b'\x8d'.join(lines[:1] + lines))))
        muts.append(('truncate one byte', *pack(target[:-1])))
    else:
        # Empty is the correct answer here -- so ANY content is a mutant.
        muts.append(('spurious output', ENC(b'x\n'), err))
        muts.append(('spurious diagnostic',
                     ENC(b'sort: cannot open /mnt/MAUX/E2E/FUNS\n'), err))
    return muts


def _aggregate_teeth():
    """Teeth for the one check that is not per-case: the exit-status
    column."""
    problems = []
    case = CASES[0]
    good = C.Verdict(case, True)

    lines, nfail = C.format_report([good], [0], [0])
    if nfail:
        problems.append('format_report flagged a clean run')

    lines, nfail = C.format_report([good], [2], [0])
    if not nfail:
        problems.append('an exit status of 2 against a reference 0 was '
                        'NOT flagged')

    ruled = copy.copy(case)
    ruled.status_ruled = ('tee', 'self-output reopens stdin target')
    lines, nfail = C.format_report([C.Verdict(ruled, True)], [1], [0])
    if nfail:
        problems.append('a status_ruled mismatch was still counted as '
                        f'a failure: {lines}')
    if not any('STATUS RULED' in ln for ln in lines):
        problems.append('a status_ruled mismatch was not reported by name')
    return problems


def _defect_registry_teeth(hostdir):
    """Teeth for the KNOWN_DEFECTS membership fix, 2026-08-23 (docs/E2E.md
    sec 9.9's mechanism, the same failure reached from the other table):
    before this fix, `check_citations()` validated `case.diverges`
    against DIVERGENCE but never looked at `case.defect` at all, and
    `judge()` treated ANY non-None `case.defect` as authorising a DEFECT
    verdict. Reproduced by hand before this fix shipped: a case mutated
    to `defect=('bogus', 'a reason that does not exist')` made judge()
    absorb a WRONG answer as a green PINNED DEFECT, silently, with
    check_citations() reporting nothing.

    Uses the corpus's own REAL pinned case (the `tr` usage-error entry)
    for both halves rather than a synthetic one -- this stage has a
    single flat KNOWN_DEFECTS dict every case shares, so a shallow copy
    with `defect=` overwritten is enough to prove both the unregistered-
    and registered-key paths without disturbing the real corpus or its
    fixtures.

    CORRECTION, 2026-08-24: the paragraph above is no longer accurate
    about WHERE the fixture comes from -- see the comment below. It
    borrowed the corpus's real `tr` pin; that pin has since been retired
    (T3's getopt/tr fix), so the fixture is synthesised now. The rest of
    the docstring still describes what these teeth prove."""
    # -- CORRECTED 2026-08-24 (integration). This used to `return
    # -- ['no case in CASES cites a KNOWN_DEFECTS entry ...']` -- i.e.
    # -- it treated "the codebase currently has NO known defects" as a
    # -- FAILURE. That is backwards: an empty KNOWN_DEFECTS is the
    # -- healthy end state these teeth exist to protect, and reaching it
    # -- must not turn the gate red.
    # --
    # -- It went red for real. T3's getopt/tr work retired the table's
    # -- last entry (the `tr -s` usage-error pin, case 23) -- correctly,
    # -- and the DEFECT-FIXED verdict is what noticed. Merged with T4's
    # -- registry enforcement, which was written when that pin still
    # -- existed and borrowed it as its fixture, the two are individually
    # -- right and jointly red. Same shape as the ps EXEMPTIONS drift in
    # -- e2e_fs_selftest.py: neither branch can see it alone.
    # --
    # -- So the teeth now SYNTHESISE their fixture instead of borrowing a
    # -- real pin: a key registered in KNOWN_DEFECTS for the duration of
    # -- this check and removed in `finally`. It proves the same two
    # -- paths (unregistered key refused, registered key honoured) with
    # -- no dependency on the corpus carrying a live defect, and leaves
    # -- no permanent entry for the dead-entry check to trip over.
    fixture_key = None
    real = next((c for c in CASES if c.defect is not None), None)
    if real is None:
        fixture_key = ('*', 'selftest fixture -- not a real defect')
        D.KNOWN_DEFECTS[fixture_key] = (
            'Injected by _defect_registry_teeth() for the length of this '
            'check only, because KNOWN_DEFECTS is empty -- which is the '
            'GOOD state. Proves the registered-key path without a live '
            'bug to borrow. Removed again in finally; never written to '
            'the table on disk.')
        real = copy.copy(CASES[0])
        real.defect = fixture_key
    try:
        return _registry_teeth_body(real, hostdir)
    finally:
        if fixture_key is not None:
            D.KNOWN_DEFECTS.pop(fixture_key, None)


def _registry_teeth_body(real, hostdir):
    problems = []
    ref_out, ref_err, _status, ref_extra = real.reference(hostdir)
    out, err = synth(real, ref_out, ref_err, ref_extra, hostdir)
    want = ref_out + ref_err

    bogus = copy.copy(real)
    bogus.defect = ('bogus', 'a reason that does not exist')

    # -- 1a. check_citations() flags the unregistered key -- the SAME
    #        shape an unregistered diverges= citation already gets.
    errs, _dead = D.check_citations([bogus])
    if not any('bogus' in e and 'KNOWN_DEFECTS' in e for e in errs):
        problems.append(
            'check_citations() did not flag a case citing an '
            f'unregistered defect key -- the membership check is '
            f'vacuous (errs={errs!r})')

    # -- 1b. judge() itself refuses too, independent of whether
    #        check_citations ran first -- defense in depth, since
    #        judge() is what actually decides a run's verdict.
    try:
        C.judge(bogus, ENC(b'nonsense\n'), want, ref_extra, hostdir)
    except ValueError as e:
        if 'bogus' not in str(e):
            problems.append(
                f'judge() raised on an unregistered defect key, but the '
                f'message does not name it: {e}')
    else:
        problems.append(
            "judge() did NOT raise on defect=('bogus', ...) -- an "
            "unregistered defect key was silently absorbed as a valid "
            "pin, which is the exact bug this fix closes")

    # -- 2. The REAL registered key still works exactly as it did before
    #       this fix: a wrong answer is absorbed as DEFECT, a right one
    #       breaks the pin as DEFECT-FIXED. (run()'s own main loop below
    #       already proves this for every real pin every run; this is
    #       the same proof, isolated and independently nameable.)
    wrong = C.judge(real, ENC(b'nonsense\n'), want, ref_extra, hostdir)
    right = C.judge(real, out, want, ref_extra, hostdir)
    if not (wrong.ok and wrong.kind == 'DEFECT'):
        problems.append(
            f'registered-key regression: case {real.cid} pinned to '
            f'{real.defect!r} -- a WRONG answer was not absorbed as '
            f'DEFECT (got ok={wrong.ok} kind={wrong.kind!r})')
    elif right.ok or right.kind != 'DEFECT-FIXED':
        problems.append(
            f'registered-key regression: case {real.cid} pinned to '
            f'{real.defect!r} -- a CORRECT answer did not break the pin '
            f'(got ok={right.ok} kind={right.kind!r})')
    return problems


def run(verbose=False):
    hostdir = tempfile.mkdtemp(prefix='maux-e2e-selftest-')
    try:
        write_host_corpus(hostdir)
        accepted = rejected = 0
        problems = []
        for case in CASES:
            ref_out, ref_err, _status, ref_extra = case.reference(hostdir)
            out, err = synth(case, ref_out, ref_err, ref_extra, hostdir)
            want = ref_out + ref_err
            if case.defect is not None:
                # A pinned case has its own two-sided contract, and both
                # sides need teeth: a WRONG answer must be absorbed as
                # the recorded defect, and a RIGHT one must break the pin
                # so nobody has to remember to unpin it by hand.
                wrong = C.judge(case, ENC(b'nonsense\n'), want, ref_extra,
                                hostdir)
                right = C.judge(case, out, want, ref_extra, hostdir)
                if not (wrong.ok and wrong.kind == 'DEFECT'):
                    problems.append(
                        f'case {case.cid}: pinned to {case.defect!r} but a '
                        f'wrong answer was not absorbed as the defect')
                elif right.ok or right.kind != 'DEFECT-FIXED':
                    problems.append(
                        f'case {case.cid}: pinned to {case.defect!r} but a '
                        f'CORRECT answer did not break the pin -- the '
                        f'entry could outlive the bug')
                else:
                    accepted += 1
                    rejected += 1
                continue
            v = C.judge(case, out, want, ref_extra, hostdir)
            if v.ok:
                accepted += 1
            else:
                problems.append(
                    f'case {case.cid} ({case.tool} {" ".join(case.mflags)}): '
                    f'comparator REJECTED a correct synthetic answer -- '
                    f'{v.detail}')
            for label, mout, merr in _mutants(case, out, err):
                mv = C.judge(case, mout, want, ref_extra, hostdir)
                if mv.ok:
                    problems.append(
                        f'case {case.cid} ({case.tool} '
                        f'{" ".join(case.mflags)}): comparator ACCEPTED a '
                        f'mutant ({label}) -- it is measuring nothing')
                else:
                    rejected += 1
        problems.extend(_aggregate_teeth())
        problems.extend(_defect_registry_teeth(hostdir))
        errs, dead = D.check_citations(CASES)
        problems.extend(f'divergence citation error: {e}' for e in errs)
        problems.extend(f'dead divergence entry: {d}' for d in dead)

        print(f'[e2e-selftest] {len(CASES)} cases: {accepted} correct '
              f'answers accepted, {rejected} mutants rejected, '
              f'{len(D.DIVERGENCE)} divergence entries')
        for p in problems:
            print(f'[e2e-selftest] FAIL: {p}', file=sys.stderr)
        if problems:
            return 1
        print('[e2e-selftest] PASS: every comparator accepts a correct '
              'answer and rejects every mutation of it')
        return 0
    finally:
        shutil.rmtree(hostdir, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(run('-v' in sys.argv))
