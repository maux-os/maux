#!/usr/bin/env python3
"""Decode maux output, run the comparators, produce per-case verdicts.

WHERE NORMALISATION HAPPENS, AND WHERE IT REFUSES TO.

`decode_maux_text` below is the ONLY place a maux byte is altered before
comparison, and it is deliberately ungenerous.  maux text is high-bit
ASCII with $8D line endings; the host's is low-ASCII with $0A.  The
obvious normaliser -- "clear bit 7 on everything, map CR to LF" -- would
accept BOTH encodings, and that is precisely the hole `tr`'s 2026-08-23
bug lived in (uninitialised buffer state that "worked only because `ds`
emitted zeros").  So instead:

    every byte of a text output MUST have bit 7 set.  A byte that does
    not is recorded, with its offset, as a FAILURE of that case.

That turns "maux emitted a low-ASCII byte" -- a thing that can only come
from uninitialised memory or a lost `ora #$80` -- from an invisible
success into a named failure.  A raw (`-b`) output is not decoded at all.

Everything else this module does is bookkeeping.  The judgement about
what may legitimately differ lives in scripts/e2e_divergence.py, one
entry at a time.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_divergence as D  # noqa: E402


class Verdict:
    def __init__(self, case, ok, detail='', status_ok=True, kind='PASS'):
        self.case = case
        self.ok = ok
        self.detail = detail
        self.status_ok = status_ok
        self.kind = kind

    def __repr__(self):
        return f'<Verdict {self.case.cid} {"ok" if self.ok else "FAIL"}>'


def decode_maux_text(data):
    """maux text bytes -> host text bytes, plus the bytes that had no
    business being there.  Returns (host_bytes, problems), problems being
    a list of (offset, byte) for every byte without bit 7 set."""
    problems = [(i, b) for i, b in enumerate(data) if not (b & 0x80)]
    stripped = bytes(b & 0x7F for b in data)
    return stripped.replace(b'\r', b'\n'), problems


def encode_maux_text(data):
    """The inverse, used only by the host-side self-test to synthesise
    what a CORRECT maux would have emitted.  Never used on real output."""
    return bytes((b | 0x80) for b in data.replace(b'\n', b'\r'))


def merge_streams(events, bufsiz=512):
    """What a maux `CMD > F 2>&1` merged capture holds, under liba
    stdio's PROBED buffering policy (docs/PERF-PLAN.md step 4,
    2026-08-28): stdout to a file is FULLY buffered -- it reaches the
    fd only at each buffer fill and at the exit flush -- while
    stderr is pinned to line mode and lands at the moment each line is
    emitted. `events` is the program's emission order as
    ('out'|'err', bytes) pairs, in MAUX text encoding. Deterministic:
    both flush points and stderr landings are fixed by the byte
    counts, so an authored expectation built through this helper stays
    exact. Every full-mode buffer flushes at 512 -- the stage owner's
    upper-half buffer included (stdio.s SIO_MODEOF's stage-owner
    note). Before the probed policy, stdout was line-buffered too and
    the merged order equaled emission order -- expectations built on
    that assumption are what this helper replaced (check-writefail's
    tee capture, e2e-fs's file/df/ls-truncation cases)."""
    out = bytearray()
    buf = bytearray()
    for kind, data in events:
        if kind == 'out':
            buf += data
            while len(buf) >= bufsiz:
                out += buf[:bufsiz]
                del buf[:bufsiz]
        else:
            out += data
    out += buf
    return bytes(out)


def judge(case, raw_out, ref_out, ref_extra, hostdir, maux_err=b''):
    """One case's verdict.  `raw_out` is the case's output file, verbatim
    -- stdout and stderr both, since every case runs `> Onn 2>&1`.

    MEMBERSHIP, not mere non-None-ness (fix, 2026-08-23): a `case.defect`
    used to authorise a DEFECT verdict just by being set -- any string
    pair, including one naming no KNOWN_DEFECTS entry at all, silently
    absorbed a WRONG answer as a pinned defect. Reproduced before this
    fix: a case mutated in memory to `defect=('bogus', 'no such entry')`
    made a WRONG output pass as a green PINNED DEFECT. This RAISES
    rather than returning a failing Verdict -- an unregistered defect
    key is a bug in how the case was built (a typo, or a key deleted
    from KNOWN_DEFECTS without updating its citations), not a
    differential result a report can absorb and move past; it must stop
    the run loudly, the same way Registry.add_module's duplicate-key
    checks do for a malformed case elsewhere in this tree, not surface
    as one more line in a report a reader might skim past."""
    if case.defect is not None and case.defect not in D.KNOWN_DEFECTS:
        raise ValueError(
            f'case {case.cid} ({case.tool}): defect={case.defect!r} is '
            f'not a key of e2e_divergence.KNOWN_DEFECTS -- a wrong '
            f'answer must never be absorbed as a pinned defect that '
            f'names nothing; register the entry (or fix the citation), '
            f'do not invent a reason at the call site')
    got, problems = decode_maux_text(raw_out)
    if problems:
        head = ', '.join(f'offset {o} = ${b:02X}' for o, b in problems[:6])
        return Verdict(case, False,
                       f'{len(problems)} byte(s) in maux output have bit 7 '
                       f'CLEAR -- maux text is high-bit ($8D line endings), '
                       f'so this is not text this system wrote correctly: '
                       f'{head}', kind='ENCODING')

    fn = D.COMPARATORS[case.compare]
    ok, detail = fn(case, got, ref_out, ref_extra, hostdir)
    if not ok and case.defect is not None:
        # A pinned defect: reported every run, by name, but not counted
        # as a failure -- see e2e_divergence.KNOWN_DEFECTS.  If it starts
        # PASSING, that is the prompt to delete the entry, and the
        # runner says so.
        return Verdict(case, True, detail, kind='DEFECT')
    if ok and case.defect is not None:
        return Verdict(case, False,
                       f'this case is pinned to KNOWN_DEFECTS entry '
                       f'{case.defect!r} but now AGREES with the '
                       f'reference -- the defect is fixed; delete the '
                       f'entry and the `defect=` citation',
                       kind='DEFECT-FIXED')
    return Verdict(case, ok, detail)


def format_report(verdicts, statuses, ref_statuses):
    """The gate's own output.  Failures first, in full."""
    lines = []
    failed = [v for v in verdicts if not v.ok]
    pinned = [v for v in verdicts if v.kind == 'DEFECT']
    for v in failed:
        c = v.case
        lines.append(f'FAIL case {c.cid:3d}  {c.sh_line()}')
        if c.note:
            lines.append(f'    note: {c.note}')
        if c.diverges:
            lines.append(f'    cites: {c.diverges}')
        for line in str(v.detail).splitlines():
            lines.append(f'    {line}')
        lines.append('')
    pinned_cids = {v.case.cid for v in pinned}
    bad_status = []
    for c, got, want in zip([v.case for v in verdicts], statuses,
                            ref_statuses):
        if got != want and c.cid not in pinned_cids:
            status_ruled = getattr(c, 'status_ruled', None)
            if status_ruled is not None:
                lines.append(
                    f'STATUS RULED case {c.cid:3d} {status_ruled} -- '
                    f'maux exit status {got}, reference {want} '
                    f'({c.sh_line()})')
                continue
            bad_status.append(
                f'FAIL case {c.cid:3d}  exit status {got}, reference '
                f'{want}   ({c.sh_line()})')
    lines.extend(bad_status)
    for v in pinned:
        c = v.case
        lines.append(f'PINNED DEFECT case {c.cid:3d}  {c.sh_line()}')
        lines.append(f'    {c.defect[0]}: {c.defect[1]}')
        for line in str(v.detail).splitlines()[:4]:
            lines.append(f'    {line}')
    return lines, len(failed) + len(bad_status)
