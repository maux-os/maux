#!/usr/bin/env python3
"""teeth_lib.py -- the one sabotage ("teeth") runner behind every
scripts/teeth_*.py (docs/HYG-4.md; design rev 2 in docs/HYG-4-NOTES.md
sec 5).

NOT a gate and in no sweep. Its self-test (`make check-teeth-lib`) is in
preflight; its static pattern lint (`make check-teeth-patterns`, which
is `--dry` on every runner) is in the sweep.

A runner is data: it declares TEETH and calls main(). A tooth is some
edits and a list of CHECKS. A check is one gate Invocation, the reporter
that reads its output, and a typed assertion about what RED means:
Rows (named rows go red, controls stay green), FailureMarker (an
anchored marker in the failure channel) or Aggregate (the gate exposes
no rows: an anchored predicate on its output). RED always needs three
things: the gate's own complete terminal verdict line saying FAIL, an
exit status that agrees, and the spec's assertion. `make` turning a
gate's exit 1 into 2 therefore never satisfies RED by itself.

Exit status: 0 every tooth behaved as declared (and at least one ran);
1 the runner worked and a tooth did not behave (the product is the
finding); 2 the runner, a spec or the environment is broken: an
unknown selector, an empty run, a lint error, a stale pattern, a
failing build/baseline, a witness that did not move, a gate it cannot
read (no terminal line, a signal, a timeout, a Traceback), a restore
that is not byte-identical.

Restore is from the BYTES captured before any edit, atomically, in a
`finally`: never `git checkout`, which destroys an uncommitted edit
already there. GNU make 3.81 compares whole-second mtimes, so the
library owns the wait (learning:01M0P0AE3G3P2VSMYTZ2KEBAKB): nothing is
written within SETTLE seconds of the last build or write, and the
declared artifacts are deleted before every rebuild.

  teeth_X.py [selector ...]   run (no selector = every tooth)
  teeth_X.py --dry            STATIC lint: schema, selectors, patterns
  teeth_X.py --list           the tooth names
  teeth_X.py --observe ...    run, print what happened, judge nothing
  teeth_lib.py --selftest     the library's own self-test (< 2 s)
  teeth_lib.py --selftest-mtime   the real GNU make wait, by hand
"""
import hashlib
import io
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tokenize
from collections import namedtuple
from contextlib import redirect_stdout
from dataclasses import dataclass
from typing import Any, Optional, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTLE = 2.1                       # GNU make 3.81: whole-second mtimes
TIMEOUT = 3600                     # default seconds for one command

RED, GREEN_EQUIVALENT, GREEN_PROOF = 'RED', 'GREEN_EQUIVALENT', 'GREEN_PROOF'
ALL, ANY = 'ALL', 'ANY'
PREFIX, TOKEN, SUBSTRING, EXACT = 'PREFIX', 'TOKEN', 'SUBSTRING', 'EXACT'
#: unset before a gate runs, never inherited (a race run is explicit)
CLEAN_ENV = ('MAUX_GATE_RACE', 'MAUX_GATE_LAG', 'MAUX_GATE_SITE',
             'MAUX_GATE_TRACE')


class RunnerFailure(Exception):
    """The runner, a spec or the environment is broken: exit 2."""


# ---------------------------------------------------------------------
# the spec
# ---------------------------------------------------------------------
@dataclass
class Edit:
    file: str
    old: str
    new: str
    count: int = 1                 # how many times `old` must occur
    regex: bool = False            # `old` is a regex
    comment_ok: Optional[str] = None   # why a comment-only span is meant


@dataclass(frozen=True)
class Invocation:
    """What is run, and the key a baseline is cached on."""
    cmd: Any                       # shell string, or argv tuple
    setup: Tuple[str, ...] = ()    # shell commands run first, must exit 0
    cwd: Optional[str] = None
    env: Any = ()                  # {name: value}, applied after CLEAN_ENV
    timeout: float = TIMEOUT
    fixture: str = ''              # names state the gate needs fresh

    def __post_init__(self):
        if isinstance(self.cmd, list):
            object.__setattr__(self, 'cmd', tuple(self.cmd))
        if isinstance(self.setup, list):
            object.__setattr__(self, 'setup', tuple(self.setup))
        if isinstance(self.env, dict):
            object.__setattr__(self, 'env', tuple(sorted(self.env.items())))

    def text(self):
        return self.cmd if isinstance(self.cmd, str) else ' '.join(self.cmd)


@dataclass
class Rows:
    red: Tuple[str, ...] = ()      # row ids that must turn red
    controls: Tuple[str, ...] = ()  # row ids that must stay green
    rule: str = ALL


@dataclass
class FailureMarker:
    marker: str                    # '(c)', 'ASEXIT': in a failure line


@dataclass
class Aggregate:
    pred: str                      # anchored (^, MULTILINE) regex
    why: str                       # why the gate exposes no rows


@dataclass
class Check:
    inv: Any                       # Invocation, or a command string
    reporter: str                  # a key of REPORTERS
    expect: Any                    # Rows | FailureMarker | Aggregate
    baseline: Any = None           # Invocation for the clean tree
    tag: Optional[str] = None      # the gate's [check-X] tag
    race: bool = False             # the spec sets MAUX_GATE_* on purpose

    def __post_init__(self):
        if isinstance(self.inv, (str, list, tuple)):
            self.inv = Invocation(self.inv)
        if isinstance(self.baseline, (str, list, tuple)):
            self.baseline = Invocation(self.baseline)


@dataclass
class Path:
    name: str
    deterministic: bool = True     # restore rebuild must reproduce GOOD
    reason: str = ''               # required when not deterministic


@dataclass
class Tooth:
    name: str
    edits: Tuple[Any, ...] = ()    # Edit, or (file, old, new)
    checks: Tuple[Check, ...] = ()
    outcome: str = RED
    witness: Any = None            # default Changed()
    pair: Any = None               # GREEN_PROOF: the RED control tooth(s)
    prep: Any = None               # overrides the runner's build
    artifacts: Optional[Tuple[Any, ...]] = None
    build_fail: Optional[str] = None   # sabotage must NOT build: marker
    retired: str = ''              # why this tooth is no longer run


class Changed:
    """The sabotaged build must differ from the good one (`ANY` or
    `ALL` of the paths; default the tooth's artifacts)."""
    def __init__(self, paths=None, quant=ANY):
        self.paths, self.quant = paths, quant


class Unchanged:
    """A static tooth: the sabotage edits no byte of the artifacts."""
    def __init__(self, paths=None):
        self.paths = paths


class SourceOnly:
    """A Python-tool edit: no artifact; the edited text is the change."""


class Intrinsic:
    """No edit and no artifact to witness (a gate self-test)."""
    def __init__(self, why):
        self.why = why


class CommandMutation:
    """The mutation is made by the command itself (recorder's guest
    `--setup`), not by an edit. `probe` (Invocation) + `pred` prove it
    took effect; with none, `why` says why nothing can."""
    def __init__(self, why, probe=None, pred=None):
        self.why, self.probe, self.pred = why, probe, pred


Result = namedtuple('Result', 'status rc out')    # status: EXIT TIMEOUT SIGNAL


class Make:
    def __init__(self, *targets, timeout=TIMEOUT):
        self.inv = Invocation(('make',) + tuple(targets), timeout=timeout)

    def run(self, env):
        return env.run(self.inv)


class NoBuild:
    """A tooth whose edit needs no build (a census file, a Python tool)."""
    def run(self, env):
        return Result('EXIT', 0, '')


class Cmd:
    def __init__(self, cmd, timeout=TIMEOUT):
        self.inv = Invocation(cmd, timeout=timeout)

    def run(self, env):
        return env.run(self.inv)


class Fn:
    """A build that is a Python callable env -> (rc, out) (self-test)."""
    def __init__(self, fn):
        self.fn = fn

    def run(self, env):
        return Result('EXIT', *self.fn(env))


# ---------------------------------------------------------------------
# reporters: (out, rc, tag, cmd) -> Parsed. Row ids are anchored tokens,
# never a substring search. `terminal` is the gate's own verdict line:
# 'PASS', 'FAIL', None (absent) or 'BOTH'. `incomplete` names what a
# complete run would have printed and did not.
# ---------------------------------------------------------------------
Parsed = namedtuple('Parsed', 'rows terminal noise incomplete')
Reporter = namedtuple('Reporter', 'parse exposes_pass allow_traceback',
                      defaults=(False,))

_NOISE = re.compile(r'^(\[mcp\]|libc\+\+abi|make: \*\*\*|\s*$)')
#: output that is never a verdict (measured: the libc++abi teardown line
#: is in 19 GREEN outputs, so it is noise and NOT here)
FATAL = [re.compile(p, re.M) for p in (
    r'^Traceback \(most recent call last\)', r'No rule to make target',
    r'Segmentation fault', r'Bus error', r'Abort trap',
    r'missing -- make')]


def _scan(out, pass_rx, fail_rx):
    rows, noise = {}, []
    for ln in out.splitlines():
        for rx, val in [(r, 'PASS') for r in pass_rx] + \
                       [(r, 'FAIL') for r in fail_rx]:
            m = rx.match(ln)
            if m:
                if val == 'FAIL' or m.group(1) not in rows:
                    rows[m.group(1)] = val
                break
        else:
            if not _NOISE.match(ln):
                noise.append(ln)
    return rows, noise


def _terminal(out, pass_rx, fail_rx):
    p = re.search(pass_rx, out, re.M)
    f = re.search(fail_rx, out, re.M)
    if p and f:
        return 'BOTH'
    return 'FAIL' if f else 'PASS' if p else None


def _tagged_terminal(out, tag):
    if tag and tag.startswith('re:'):      # several stages, one gate
        t = tag[3:]
        p = re.search(r'^\[' + t + r'\] PASS(?:: | \(|$)', out, re.M)
        f = re.search(r'^\[' + t + r'\] FAIL: ', out, re.M)
        return 'FAIL' if f else 'PASS' if p else None
    t = re.escape(tag or 'check-[\\w-]+')
    return _terminal(out, r'^\[' + t + r'\] PASS(?:: | \(|$)',
                     r'^\[' + t + r'\] FAIL: ')


def _devfs(out, rc, tag, cmd):
    rows, noise = _scan(
        out, [re.compile(r'^\[check-devfs\] PASS ([^\s:]+)')],
        [re.compile(r'^  - (?:console \S+: )?([^\s:]+)')])
    return Parsed(rows, _tagged_terminal(out, tag), noise, None)


def _tagged(out, rc, tag, cmd):
    rows, noise = _scan(
        out, [re.compile(r'^\[check-[\w-]+\] (\S+): PASS$')],
        [re.compile(r'^\[check-[\w-]+\] (\S+): FAIL$'),
         re.compile(r'^  - ([^\s:]+):')])
    return Parsed(rows, _tagged_terminal(out, tag), noise, None)


def _bullets(out, rc, tag, cmd):
    rows, noise = _scan(out, [],
                        [re.compile(r'^  - (?:console \S+: )?([^\s:]+)')])
    return Parsed(rows, _tagged_terminal(out, tag), noise, None)


def _namerows(out, rc, tag, cmd):
    rows, noise = _scan(
        out, [re.compile(r'^PASS (?:shedit|tabcomp) (\S+ \[\w+\])')],
        [re.compile(r'^FAIL (?:shedit|tabcomp) (\S+ \[\w+\])')])
    # a command that names a backend and cases must print each one
    words = cmd.split()
    want, inc = set(), None
    bk = [w for w in words if w in ('text40', 'text80', 'ut')]
    if bk:
        cases = words[words.index(bk[0]) + 1:]
        want = {'%s [%s]' % (c, bk[0]) for c in cases}
    if not rows:
        inc = 'no row line was printed'
    elif want - set(rows):
        inc = 'rows never printed: %s' % sorted(want - set(rows))
    term = None if not rows else (
        'FAIL' if 'FAIL' in rows.values() else 'PASS')
    return Parsed(rows, term, noise, inc)


def _sleep(out, rc, tag, cmd):
    rows, noise = _scan(out, [re.compile(r'^\[check-sleep\] PASS (\S+)')],
                        [re.compile(r'^\[check-sleep\] FAIL (\S+?):')])
    return Parsed(rows, _tagged_terminal(out, 'check-sleep'), noise, None)


def _wait(out, rc, tag, cmd):
    rows, noise = _scan(out, [re.compile(r'^\[check-wait\] (\S+): PASS')],
                        [re.compile(r'^\[check-wait\] (\S+): FAIL')])
    return Parsed(rows, _tagged_terminal(out, 'check-wait'), noise, None)


def _recorder(out, rc, tag, cmd):
    rows, noise = _scan(out, [re.compile(r'^PASS  (.*?)(?:  \(.*)?$')],
                        [re.compile(r'^FAIL  (.*)$')])
    term = _terminal(out, r'^check-recorder: all \d+ rows pass',
                     r'^check-recorder: \d+ of \d+ rows FAILED')
    return Parsed(rows, term, noise, None)


def _ascore(out, rc, tag, cmd):
    rows = {}
    for ln in out.splitlines():
        if ln.startswith('[check-ascore] FAIL:'):
            for m in re.finditer(r'\(([a-e])\)|(ASEXIT)', ln):
                rows['(%s)' % m.group(1) if m.group(1) else m.group(2)] = \
                    'FAIL'
    term = _terminal(out, r'^\[check-ascore\] PASS',
                     r'^\[check-ascore\] FAIL:')
    return Parsed(rows, term, [], None)


def _jobctl(out, rc, tag, cmd):
    rows, noise = _scan(
        out, [re.compile(r'^\[check-jobctl-[ab]\] ok   (\S+)')],
        [re.compile(r'^\[check-jobctl-a\] FAIL (\S+):')])
    return Parsed(rows, _tagged_terminal(out, tag), noise, None)


def _fdact(out, rc, tag, cmd):
    # check_fdact prints one PASS/FAIL line per check and NO summary line
    # (environment failures use the same `FAIL:` channel): it is complete
    # when it reached its last check, `K5 the positives left ...`
    fail = re.search(r'^\[check-fdact\] FAIL:', out, re.M)
    last = re.search(r'^\[check-fdact\] PASS: K5 the positives left', out,
                     re.M)
    term = 'FAIL' if fail else 'PASS' if last else None
    return Parsed({}, term, [], None)


def _demo(out, rc, tag, cmd):
    # scripts/demo_record.py: `PASS mygrep (gate mode, 8 checks)` or
    # `FAIL mygrep (gate mode): <label>: <why>`
    term = _terminal(out, r'^PASS \S+ \(gate mode', r'^FAIL \S+ \(gate mode\)')
    return Parsed({}, term, [], None)


def _assertion(out, rc, tag, cmd):
    # check_more.py / check_play.py print `[tag] PASS` (or a `[tag] FAIL:`
    # line) or die on the harness's own exception: an AssertionError, or
    # the RuntimeError a screen wait raises (`timed out waiting for ..;
    # screen was:`). Those are the gate's failure channel; any other
    # exception is a crash and stays unreadable.
    t = re.escape(tag or 'check-[\\w-]+')
    if re.search(r'^\[' + t + r'\] FAIL: ', out, re.M):
        return Parsed({}, 'FAIL', [], None)
    if re.search(r'^\[' + t + r'\] PASS', out, re.M):
        return Parsed({}, 'PASS', [], None)
    m = re.search(r'^Traceback \(most recent call last\):\n(?:.*\n)*?'
                  r'(\w[\w.]*(?:Error|Exception)\b[^\n]*)$', out, re.M)
    if m and (m.group(1).startswith('AssertionError') or
              m.group(1).startswith('RuntimeError: timed out waiting for')):
        return Parsed({}, 'FAIL', [], None)
    return Parsed({}, None, [], None)


def _aggregate(out, rc, tag, cmd):
    return Parsed({}, _tagged_terminal(out, tag), [], None)


REPORTERS = {
    'devfs': Reporter(_devfs, True),        # [check-devfs] PASS ROW / - ROW
    'tagged': Reporter(_tagged, True),      # [check-X] TAG: PASS|FAIL
    'bullets_only': Reporter(_bullets, False),   # failure bullets only
    'namerows': Reporter(_namerows, True),  # PASS|FAIL shedit CASE [be]
    'sleep': Reporter(_sleep, True),
    'wait': Reporter(_wait, True),
    'recorder': Reporter(_recorder, True),
    'fdact': Reporter(_fdact, False),       # no ids; row-shaped FAIL lines
    'jobctl': Reporter(_jobctl, True),      # [check-jobctl-a] ok NAME / FAIL
    'ascore': Reporter(_ascore, False),     # (a)..(e) markers
    'demo': Reporter(_demo, False),         # demo_record.py PASS|FAIL line
    'assertion': Reporter(_assertion, False, True),  # AssertionError = FAIL
    'aggregate': Reporter(_aggregate, False),   # no rows
}


def tag_of(cmd):
    """The gate's [check-X] tag, from `check_x.py` or `make check-x`."""
    m = re.search(r'check[_-][\w-]+?(?=\.py|\s|$)', cmd)
    return m.group(0).replace('_', '-') if m else None


# ---------------------------------------------------------------------
# comment-aware edit spans (M2)
# ---------------------------------------------------------------------
def _comment_mask(text, name):
    """-> bytearray, 1 where the character is comment text."""
    mask = bytearray(len(text))
    if name.endswith('.py'):
        try:
            offs, o = [], 0
            for ln in text.splitlines(True):
                offs.append(o)
                o += len(ln)
            for tok in tokenize.generate_tokens(io.StringIO(text).readline):
                if tok.type == tokenize.COMMENT:
                    a = offs[tok.start[0] - 1] + tok.start[1]
                    b = offs[tok.end[0] - 1] + tok.end[1]
                    mask[a:b] = b'\x01' * (b - a)
            return mask
        except (tokenize.TokenError, IndentationError, SyntaxError):
            mask = bytearray(len(text))     # fall through to the line rule
    asm = name.endswith(('.s', '.i'))
    pos = 0
    for ln in text.splitlines(True):
        body = ln.rstrip('\r\n')
        cut = None
        if asm and body[:1] in ('*', ';'):
            cut = 0
        elif asm:
            q = None
            for i, ch in enumerate(body):
                if q:
                    q = None if ch == q else q
                elif ch in '\'"':
                    q = ch
                elif ch == ';':
                    cut = i
                    break
        elif body.lstrip()[:1] == '#':
            cut = 0
        if cut is not None:
            mask[pos + cut:pos + len(ln)] = b'\x01' * (len(ln) - cut)
        pos += len(ln)
    return mask


def _spans(e, text):
    if e.regex:
        return [(m.start(), m.end()) for m in re.finditer(e.old, text)]
    out, i = [], text.find(e.old)
    while i >= 0:
        out.append((i, i + len(e.old)))
        i = text.find(e.old, i + max(1, len(e.old)))
    return out


def _has_code(text, spans, name):
    mask = _comment_mask(text, name)
    return any(not mask[i] and not text[i].isspace()
               for a, b in spans for i in range(a, b))


# ---------------------------------------------------------------------
# the environment (injectable: the self-test replaces all of it)
# ---------------------------------------------------------------------
class Env:
    def __init__(self, root=ROOT):
        self.root = root

    def clock(self):
        return time.time()

    def sleep(self, s):
        time.sleep(s)

    def run(self, inv):
        """Run one Invocation: own process group, a timeout, a clean
        environment. -> Result(status, rc, output)."""
        e = {k: v for k, v in os.environ.items() if k not in CLEAN_ENV}
        e.update(dict(inv.env))
        out = ''
        for s in inv.setup:
            r = self._spawn(s, e, inv)
            if r.status != 'EXIT' or r.rc != 0:
                return Result(r.status, r.rc,
                              'setup %r failed:\n%s' % (s, r.out))
            out += r.out
        r = self._spawn(inv.cmd, e, inv)
        return Result(r.status, r.rc, out + r.out)

    def _spawn(self, cmd, e, inv):
        p = subprocess.Popen(cmd, shell=isinstance(cmd, str),
                             cwd=inv.cwd or self.root, env=e, text=True,
                             errors='replace', stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE,
                             start_new_session=True)
        # stdout then stderr, not interleaved on one pipe: a block-buffered
        # stdout listing flushed in chunks can end mid-line, and the
        # gate's `[check-X] FAIL:` line on stderr would land glued to it
        # and miss every anchored match (measured on check-shwarm)
        try:
            out, err = p.communicate(timeout=inv.timeout)
            out = out + ('\n' if out and not out.endswith('\n') else '') + err
        except subprocess.TimeoutExpired:
            # TERM first (a polite gate cleans up), then ALWAYS KILL the
            # whole group: a grandchild that ignores TERM and has closed
            # its stdio outlives communicate() returning (reproduced)
            out = err = ''
            done = False
            self._signal_group(p, signal.SIGTERM)
            try:
                out, err = p.communicate(timeout=3)
                done = True
            except subprocess.TimeoutExpired:
                pass
            self._signal_group(p, signal.SIGKILL)
            if not done:
                try:
                    out, err = p.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    out, err = '', ''
            p.wait()
            return Result('TIMEOUT', None, (out or '') + (err or ''))
        if p.returncode < 0:
            return Result('SIGNAL', p.returncode, out)
        return Result('EXIT', p.returncode, out)

    @staticmethod
    def _signal_group(p, sig):
        try:
            os.killpg(p.pid, sig)               # our own group only
        except ProcessLookupError:
            pass

    def path(self, p):
        return p if os.path.isabs(p) else os.path.join(self.root, p)

    def read(self, p):
        with open(self.path(p), 'rb') as f:
            return f.read().decode('latin-1')

    def write(self, p, text):
        """Atomic: a temp file beside it, the mode kept, then rename."""
        dst = self.path(p)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst) or '.',
                                   prefix='.teeth-')
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(text.encode('latin-1'))
            if os.path.exists(dst):
                shutil.copymode(dst, tmp)
            os.replace(tmp, dst)
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise

    def exists(self, p):
        return os.path.exists(self.path(p))

    def remove(self, p):
        if self.exists(p):
            os.remove(self.path(p))

    def sha(self, p):
        if not self.exists(p):
            return None
        with open(self.path(p), 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()


# ---------------------------------------------------------------------
# the runner
# ---------------------------------------------------------------------
def _norm_edit(e):
    return e if isinstance(e, Edit) else Edit(*e)


def _pname(p):
    return p.name if isinstance(p, Path) else p


def _apply(e, text):
    if e.regex:
        return re.sub(e.old, lambda m: e.new, text, count=e.count)
    return text.replace(e.old, e.new, e.count)


def _key(c):
    """What a GREEN_PROOF pair must match."""
    return (c.inv.text(), c.reporter, type(c.expect).__name__)


class Runner:
    def __init__(self, name, specs, prep=None, artifacts=(), match=PREFIX,
                 env=None, settle=SETTLE, out=None):
        self.name = name
        self.specs = list(specs)
        self.prep = prep
        self.artifacts = tuple(artifacts)
        self.match = match
        self.env = env or Env()
        self.settle_s = settle
        self.mark = self.env.clock()
        self.good = {}
        self.base = {}                 # Invocation -> (Result, Parsed)
        self.p = out or (lambda s: print(s, flush=True))

    # -- selection ----------------------------------------------------
    def _matches(self, sel, t):
        if self.match == EXACT:
            return sel == t.name or sel == t.name.split()[0]
        if self.match == TOKEN:
            return sel == t.name.split()[0]
        if self.match == SUBSTRING:
            return sel in t.name
        return t.name.startswith(sel)

    @staticmethod
    def _pairs(t):
        if not t.pair:
            return ()
        return (t.pair,) if isinstance(t.pair, str) else tuple(t.pair)

    def select(self, selectors):
        if not self.specs:
            raise RunnerFailure('the runner declares no teeth')
        if not selectors:
            chosen = list(self.specs)
        else:
            chosen = []
            for sel in selectors:
                hit = [t for t in self.specs if self._matches(sel, t)]
                if not hit:
                    raise RunnerFailure(
                        'selector %r matches no tooth (%s match); teeth: %s'
                        % (sel, self.match, ', '.join(
                            t.name.split()[0] for t in self.specs)))
                chosen += [t for t in hit if t not in chosen]
        by = {t.name: t for t in self.specs}
        for t in list(chosen):
            for pn in self._pairs(t):
                if pn in by and by[pn] not in chosen:
                    chosen.insert(chosen.index(t), by[pn])
                    self.p('note: %s needs its paired control %s; running '
                           'both' % (t.name.split()[0], pn.split()[0]))
        return chosen

    # -- the static lint (reads the edited files, nothing else) -----
    def lint(self):
        errs, names = [], set()
        by = {t.name: t for t in self.specs}
        for t in self.specs:
            who = t.name
            if t.name in names:
                errs.append('%s: duplicate tooth name' % who)
            names.add(t.name)
            if t.retired and not t.retired.strip():
                errs.append('%s: a retired tooth states its reason' % who)
            if not t.checks and not t.build_fail:
                errs.append('%s: no checks' % who)
            if t.build_fail and t.checks:
                errs.append('%s: a build_fail tooth runs no checks (they '
                            'would never be judged); drop one of them' % who)
            if t.outcome not in (RED, GREEN_EQUIVALENT, GREEN_PROOF):
                errs.append('%s: unknown outcome %r' % (who, t.outcome))
            w = t.witness
            if w is not None and not isinstance(
                    w, (Changed, Unchanged, SourceOnly, Intrinsic,
                        CommandMutation)):
                errs.append('%s: unknown witness' % who)
            if not t.edits and t.prep is None and not isinstance(
                    w, (Intrinsic, CommandMutation)):
                errs.append('%s: no edits needs its own prep (the mutation '
                            'is in the build) or witness=Intrinsic(why) / '
                            'CommandMutation(why)' % who)
            if isinstance(w, (CommandMutation, Intrinsic)) and not w.why:
                errs.append('%s: %s needs a why' % (who, type(w).__name__))
            if isinstance(w, CommandMutation) and w.probe is not None:
                if not w.pred:
                    errs.append('%s: a mutation probe needs a pred (an '
                                'empty one matches every output)' % who)
                else:
                    try:
                        re.compile(w.pred, re.M)
                    except re.error as e:
                        errs.append('%s: bad probe pred: %s' % (who, e))
            if isinstance(w, Changed) and w.quant not in (ANY, ALL):
                errs.append('%s: witness quantifier must be ANY or ALL' % who)
            for p in list(getattr(w, 'paths', None) or ()) + list(
                    t.artifacts or ()) + list(self.artifacts):
                if isinstance(p, Path) and not p.deterministic \
                        and not p.reason:
                    errs.append('%s: %s is non-deterministic and gives no '
                                'reason' % (who, p.name))
            for e in map(_norm_edit, t.edits):
                if e.old == e.new:
                    errs.append('%s: an edit of %s changes nothing'
                                % (who, e.file))
                if e.count < 1:
                    errs.append('%s: edit count < 1' % who)
            for c in t.checks:
                errs += self._lint_check(t, c)
            if t.outcome == GREEN_PROOF:
                errs += self._lint_pair(t, by)
            elif t.pair:
                errs.append('%s: `pair` only on a GREEN_PROOF tooth' % who)
        return errs

    def _lint_check(self, t, c):
        who, errs = t.name, []
        if c.reporter not in REPORTERS:
            return ['%s: unknown reporter %r' % (who, c.reporter)]
        rep = REPORTERS[c.reporter]
        ex = c.expect
        if not isinstance(ex, (Rows, FailureMarker, Aggregate)):
            return ['%s: expect must be Rows, FailureMarker or Aggregate'
                    % who]
        for inv in (c.inv, c.baseline):
            if inv is None:
                continue
            for k, _ in inv.env:
                if k in CLEAN_ENV and not c.race:
                    errs.append('%s: %s is set in the environment of %r '
                                'without race=True (a race run is '
                                'explicit)' % (who, k, inv.text()[:50]))
        if isinstance(ex, Rows):
            if set(ex.red) & set(ex.controls):
                errs.append('%s: a row is both red and a control' % who)
            if ex.rule not in (ALL, ANY):
                errs.append('%s: unknown rule %r' % (who, ex.rule))
            if c.reporter in ('aggregate', 'ascore'):
                errs.append('%s: Rows needs a reporter that prints rows, '
                            'not %r' % (who, c.reporter))
            if t.outcome == RED and not ex.red:
                errs.append('%s: Rows names no red row' % who)
            if t.outcome != RED and ex.red:
                errs.append('%s: a green tooth names no red rows' % who)
            if ex.controls and not rep.exposes_pass:
                errs.append('%s: a control on reporter %r cannot be seen '
                            'to run (it prints no PASS rows): select it as '
                            'its own aggregate-green check with a '
                            'completion marker, or drop the claim'
                            % (who, c.reporter))
        elif isinstance(ex, FailureMarker):
            if c.reporter != 'ascore':
                errs.append('%s: FailureMarker needs reporter ascore' % who)
            if not ex.marker:
                errs.append('%s: empty marker' % who)
            if t.outcome != RED:
                errs.append('%s: FailureMarker is a RED assertion' % who)
        else:
            if rep.exposes_pass:
                errs.append('%s: Aggregate is for a reporter that prints no '
                            'rows, not %r' % (who, c.reporter))
            if not ex.why:
                errs.append('%s: Aggregate needs a why (no rows)' % who)
            try:
                re.compile(ex.pred, re.M)
            except re.error as e:
                errs.append('%s: bad Aggregate.pred: %s' % (who, e))
            if not ex.pred.startswith('^'):
                errs.append('%s: Aggregate.pred must be anchored with ^'
                            % who)
        return errs

    def _lint_pair(self, t, by):
        errs = []
        pairs = [by[p] for p in self._pairs(t) if p in by]
        if not pairs:
            return ['%s: GREEN_PROOF needs a `pair` that is a tooth of '
                    'this runner' % t.name]
        for q in pairs:
            if q.outcome != RED:
                errs.append('%s: its pair %s must be RED' % (t.name, q.name))
        red_keys = {_key(c) for q in pairs for c in q.checks}
        for c in t.checks:
            if _key(c) not in red_keys:
                errs.append('%s: its green check %r has no matching RED '
                            'check in the pair (same command, reporter and '
                            'assertion type): narrow the claim to what the '
                            'pair proves, or add a control' %
                            (t.name, c.inv.text()[:60]))
        return errs

    def patterns(self, teeth):
        """Static: every edit occurs `count` times in the files as they
        are, and its span holds code, not only a comment (M2)."""
        errs = []
        for t in teeth:
            texts = {}
            for e in map(_norm_edit, t.edits):
                if e.file not in texts:
                    if not self.env.exists(e.file):
                        errs.append('%s: no such file %s' % (t.name, e.file))
                        continue
                    texts[e.file] = self.env.read(e.file)
                text = texts[e.file]
                sp = _spans(e, text)
                if len(sp) != e.count:
                    errs.append('%s: pattern found %d time(s) in %s, wanted '
                                '%d: %r' % (t.name, len(sp), e.file, e.count,
                                            e.old.split('\n')[0][:60]))
                    continue
                if not e.comment_ok and not _has_code(text, sp, e.file):
                    errs.append('%s: the edited span in %s is only comment '
                                'text (no code): %r' % (
                                    t.name, e.file, e.old.split('\n')[0][:50]))
                texts[e.file] = _apply(e, text)
        return errs

    # -- the build, the wait, the witness ----------------------------
    def _settle(self):
        if not any(p and not isinstance(p, NoBuild) for p in
                   [self.prep] + [t.prep for t in self.specs]):
            return
        d = self.mark + self.settle_s - self.env.clock()
        if d > 0:
            self.env.sleep(d)

    def _stamp(self):
        self.mark = self.env.clock()

    def _build(self, prep, arts):
        if prep is None:
            return Result('EXIT', 0, '')
        for a in arts:
            self.env.remove(_pname(a))
        r = prep.run(self.env)
        self._stamp()
        return r

    def _arts(self, t):
        return tuple(t.artifacts if t.artifacts is not None
                     else self.artifacts)

    def _snap(self, paths):
        return {_pname(p): self.env.sha(_pname(p)) for p in paths}

    def _witness(self, t, arts, now):
        w = t.witness if t.witness is not None else Changed()
        if isinstance(w, (SourceOnly, Intrinsic, CommandMutation)):
            return 'n/a'
        paths = [_pname(p) for p in (w.paths or arts)]
        if not paths:
            raise RunnerFailure('%s: a Changed/Unchanged witness needs '
                                'artifacts' % t.name)
        moved = [p for p in paths if now.get(p) != self.good.get(p)]
        if isinstance(w, Unchanged):
            if moved:
                raise RunnerFailure(
                    '%s: a static tooth changed %s -- it was not static'
                    % (t.name, ', '.join(moved)))
            return 'unchanged'
        need = len(paths) if w.quant == ALL else 1
        if len(moved) < need:
            raise RunnerFailure(
                '%s: the sabotaged build left %s as the good one (%s of %d '
                'paths moved) -- the edit did not reach what the gate runs '
                '(stale mtime? an edit in a file the build does not read?)'
                % (t.name, ', '.join(p for p in paths if p not in moved),
                   w.quant, len(paths)))
        return 'differs'

    # -- running a gate, reading it ----------------------------------
    def classify(self, c, inv, res):
        """-> (GREEN | RED, Parsed). Anything else is a RunnerFailure:
        a command that did not complete is not a red."""
        label = inv.text()[:80]
        if res.status != 'EXIT':
            raise RunnerFailure('%r ended with %s (rc %s): not a verdict\n%s'
                                % (label, res.status, res.rc, res.out[-500:]))
        for rx in (FATAL[1:] if REPORTERS[c.reporter].allow_traceback
                   else FATAL):
            m = rx.search(res.out)
            if m:
                tail = [x for x in res.out[m.start():].splitlines()
                        if x.strip()][-14:]
                raise RunnerFailure('%r printed %r: the gate did not '
                                    'complete\n%s' % (label, m.group(0),
                                                      '\n'.join(tail)))
        rep = REPORTERS[c.reporter]
        tag = c.tag or tag_of(inv.text())
        par = rep.parse(res.out, res.rc, tag, inv.text())
        if par.incomplete:
            raise RunnerFailure('%r: incomplete output: %s\n%s'
                                % (label, par.incomplete, res.out[-700:]))
        if par.terminal in (None, 'BOTH'):
            nb = [x for x in res.out.splitlines() if x.strip()]
            raise RunnerFailure(
                '%r: no complete terminal verdict line (%s) -- rc %d\n'
                '%s%s' % (label, 'both PASS and FAIL' if par.terminal
                          else 'none', res.rc, '\n'.join(nb[:8]),
                          '\n   ...\n' + '\n'.join(nb[-8:])
                          if len(nb) > 16 else ''))
        if par.terminal == 'FAIL' and res.rc == 0:
            raise RunnerFailure('%r: FAIL verdict with exit status 0' % label)
        if par.terminal == 'PASS' and res.rc != 0:
            raise RunnerFailure('%r: PASS verdict with exit status %d'
                                % (label, res.rc))
        return ('RED' if par.terminal == 'FAIL' else 'GREEN'), par

    def judge(self, t, c, status, par, out):
        """-> (problems, collateral): the assertion against one run."""
        ex, rep, bad = c.expect, REPORTERS[c.reporter], []
        rows = par.rows
        if t.outcome == RED:
            if status != 'RED':
                return ['the gate stayed GREEN'], []
            if isinstance(ex, Rows):
                reds = [r for r in ex.red if rows.get(r) == 'FAIL']
                if ex.rule == ALL:
                    for r in ex.red:
                        if rows.get(r) != 'FAIL':
                            bad.append('row %s %s' % (r, 'stayed green'
                                       if r in rows else 'never printed'))
                else:
                    if not reds:
                        bad.append('none of %s went red' % list(ex.red))
                    if rep.exposes_pass:
                        bad += ['row %s never printed' % r
                                for r in ex.red if r not in rows]
                for r in ex.controls:
                    if rows.get(r) != 'PASS':
                        bad.append('control %s %s' % (r, 'went red'
                                   if r in rows else 'never printed'))
                coll = [r for r, v in sorted(rows.items())
                        if v == 'FAIL' and r not in ex.red]
                return bad, coll
            if isinstance(ex, FailureMarker):
                if rows.get(ex.marker) != 'FAIL':
                    bad.append('marker %s not in a failure line'
                               % ex.marker)
                return bad, []
            if not re.search(ex.pred, out, re.M):
                bad.append('red, but %r is not in the output' % ex.pred)
            return bad, []
        # GREEN_EQUIVALENT / GREEN_PROOF
        if status != 'GREEN':
            return ['the gate went RED (%s)' % ', '.join(sorted(
                k for k, v in rows.items() if v == 'FAIL'))[:120]], []
        if isinstance(ex, Rows):
            for r in ex.controls:
                if rows.get(r) != 'PASS':
                    bad.append('control %s %s' % (r, 'went red'
                               if r in rows else 'never printed'))
        elif isinstance(ex, Aggregate) and re.search(ex.pred, out, re.M):
            bad.append('the failure predicate matched a green run')
        return bad, []

    # -- baselines (H2) ----------------------------------------------
    def run_baselines(self, teeth):
        dirty = False
        for t in teeth:
            for c in t.checks:
                inv = c.baseline or c.inv
                if inv not in self.base:
                    if dirty and self.prep:
                        self._canonical()
                    self.p('baseline: %s' % inv.text()[:90])
                    res = self.env.run(inv)
                    dirty = bool(inv.setup) or bool(inv.fixture)
                    status, par = self.classify(c, inv, res)
                    self.base[inv] = (res, par)
                    if status != 'GREEN':
                        raise RunnerFailure(
                            'the clean tree is not green under %r (a '
                            'sabotage proves nothing on a red gate):\n%s'
                            % (inv.text(), res.out[-1200:]))
                res, par = self.base[inv]
                ex = c.expect
                if isinstance(ex, Rows) and REPORTERS[c.reporter].exposes_pass:
                    miss = sorted(r for r in tuple(ex.red) +
                                  tuple(ex.controls)
                                  if par.rows.get(r) != 'PASS')
                    if miss:
                        raise RunnerFailure(
                            'the clean run of %r never printed a PASS row '
                            'for %s -- a row the gate does not expose '
                            'cannot be judged (printed: %s)'
                            % (inv.text(), miss, sorted(par.rows)[:12]))
                elif isinstance(ex, Aggregate) and re.search(
                        ex.pred, res.out, re.M):
                    raise RunnerFailure('the failure predicate %r matches '
                                        'the CLEAN run of %r'
                                        % (ex.pred, inv.text()))
                elif isinstance(ex, FailureMarker) and \
                        par.rows.get(ex.marker) == 'FAIL':
                    raise RunnerFailure('marker %s is in the clean run of %r'
                                        % (ex.marker, inv.text()))

    def run_probes(self, teeth):
        """A mutation probe must DIFFER: on the clean tree its pred
        does not match (the mutation is what makes it match)."""
        seen = set()
        for t in teeth:
            w = t.witness
            if not (isinstance(w, CommandMutation) and w.probe):
                continue
            if (w.probe, w.pred) in seen:
                continue
            seen.add((w.probe, w.pred))
            res = self.env.run(w.probe)
            if res.status != 'EXIT':
                raise RunnerFailure('the probe %r ended with %s'
                                    % (w.probe.text(), res.status))
            if re.search(w.pred, res.out, re.M):
                raise RunnerFailure(
                    '%s: the mutation probe %r already matches %r on the '
                    'CLEAN tree: it cannot show the mutation'
                    % (t.name, w.probe.text()[:60], w.pred))

    def _canonical(self):
        """Regenerate the canonical artifacts from the sources as they
        are: delete, rebuild, must succeed."""
        self._settle()
        r = self._build(self.prep, self.artifacts)
        if r.status != 'EXIT' or r.rc != 0:
            raise RunnerFailure('the canonical build failed (%s %s):\n%s'
                                % (r.status, r.rc, r.out[-900:]))

    # -- one tooth ----------------------------------------------------
    def run_tooth(self, t, observe=False):
        env = self.env
        edits = [_norm_edit(e) for e in t.edits]
        files = sorted({e.file for e in edits})
        orig = {f: env.read(f) for f in files}          # BYTES, captured
        prep = t.prep or self.prep
        arts = self._arts(t)
        wrote = built = False
        result = {'name': t.name, 'ok': True, 'why': [], 'coll': [],
                  'verdicts': [], 'witness': 'n/a', 'checks': []}
        try:
            texts = dict(orig)
            for e in edits:                 # validate ALL before writing
                n = len(_spans(e, texts[e.file]))
                if n != e.count:
                    raise RunnerFailure(
                        '%s: pattern found %d time(s) in %s, wanted %d (a '
                        'sabotage that cannot apply proves nothing): %r'
                        % (t.name, n, e.file, e.count, e.old[:70]))
                texts[e.file] = _apply(e, texts[e.file])
            if edits and all(texts[f] == orig[f] for f in files):
                raise RunnerFailure('%s: the edits change no byte' % t.name)
            if files:
                self._settle()
                wrote = True
                for f in files:
                    env.write(f, texts[f])
                self._stamp()
            built = prep is not None and not isinstance(prep, NoBuild)
            r = self._build(prep, arts)
            if t.build_fail is not None:
                if r.status == 'EXIT' and r.rc != 0 and t.build_fail in r.out:
                    return result
                raise RunnerFailure('%s: the build was meant to FAIL with %r'
                                    ' and did not' % (t.name, t.build_fail))
            if r.status != 'EXIT' or r.rc != 0:
                raise RunnerFailure('%s: the sabotaged build failed (%s %s; '
                                    'a tooth whose sabotage does not build '
                                    'proves nothing):\n%s'
                                    % (t.name, r.status, r.rc, r.out[-900:]))
            now = self._snap(set(map(_pname, arts)) | set(
                _pname(p) for p in (getattr(t.witness, 'paths', None)
                                    or ()))) if prep else {}
            result['witness'] = self._witness(t, arts, now)
            for c in t.checks:
                res = env.run(c.inv)
                status, par = self.classify(c, c.inv, res)
                result['verdicts'].append(status)
                result['checks'].append((_key(c), status))
                if observe:
                    self.p('    observe: %s -> %s failed rows=%s noise=%s' % (
                        c.inv.text()[:70], status, sorted(
                            k for k, v in par.rows.items() if v == 'FAIL'),
                        par.noise[:3]))
                    for ln in [x for x in res.out.splitlines()
                               if re.search(r'FAIL|VIOLATION', x)][:3]:
                        self.p('      | %s' % ln[:160])
                    continue
                bad, coll = self.judge(t, c, status, par, res.out)
                result['coll'] += coll
                if bad:
                    result['ok'] = False
                    result['why'] += bad
            w = t.witness
            if isinstance(w, CommandMutation) and w.probe and not observe:
                res = env.run(w.probe)
                if res.status != 'EXIT' or not re.search(w.pred, res.out,
                                                         re.M):
                    result['ok'] = False
                    result['why'].append('the mutation probe did not show '
                                         'the mutation')
        finally:
            if wrote:
                self._settle()
                for f in files:
                    if env.read(f) != orig[f]:
                        env.write(f, orig[f])
                self._stamp()
                for f in files:
                    if env.read(f) != orig[f]:
                        raise RunnerFailure('%s: %s is not byte-identical '
                                            'after the restore' % (t.name, f))
            if built:
                # EVERY tooth that built anything: the sabotaged artifact
                # (a source edit, or a builder flag with no edit at all)
                # is replaced by a rebuild with the RUNNER's own prep, and
                # that must reproduce the good artifacts
                if self.prep is None:
                    raise RunnerFailure(
                        '%s: it builds with its own prep but the runner has '
                        'none to put the good artifacts back' % t.name)
                r = self._build(self.prep, arts)
                if r.status != 'EXIT' or r.rc != 0:
                    raise RunnerFailure('%s: the restore rebuild failed:\n%s'
                                        % (t.name, r.out[-600:]))
                drift = [_pname(p) for p in arts
                         if not (isinstance(p, Path)
                                 and not p.deterministic)
                         and env.sha(_pname(p))
                         != self.good.get(_pname(p))]
                if drift:
                    raise RunnerFailure(
                        '%s: after the restore %s is not the good '
                        'artifact -- every later tooth would measure a '
                        'tree that is not the one under test'
                        % (t.name, ', '.join(drift)))
        return result

    # -- the whole run ------------------------------------------------
    def go(self, selectors=(), dry=False, observe=False, list_only=False):
        teeth = self.select(selectors)
        if list_only:
            for t in teeth:
                self.p(t.name + ('   [RETIRED: %s]' % t.retired
                                 if t.retired else ''))
            return 0
        retired = [t for t in teeth if t.retired]
        teeth = [t for t in teeth if not t.retired]
        for t in retired:
            self.p('RETIRED (not run): %s -- %s' % (t.name, t.retired))
        if not teeth:
            raise RunnerFailure('every selected tooth is retired: nothing '
                                'to run')
        errs = self.lint() + self.patterns(teeth)
        if errs:
            raise RunnerFailure('%d spec problem(s):\n  - %s'
                                % (len(errs), '\n  - '.join(errs)))
        if dry:
            n = sum(len(t.edits) for t in teeth)
            self.p('%s --dry: %d teeth, %d edit patterns, all apply'
                   % (self.name, len(teeth), n))
            return 0
        paths = {_pname(a) for a in self.artifacts}
        for t in teeth:
            paths |= {_pname(a) for a in (t.artifacts or ())}
            paths |= {_pname(a) for a in (getattr(t.witness, 'paths', None)
                                          or ())}
        if self.prep:
            self._canonical()
        self.run_baselines(teeth)
        self.run_probes(teeth)
        if self.prep:
            self._canonical()                 # THEN regenerate, then GOOD
        self.good = self._snap(sorted(paths))
        for p, h in self.good.items():
            if h is None and self.prep:
                raise RunnerFailure('the good build did not produce %s' % p)
        if any(self.good.values()):
            self.p('good: ' + ' '.join('%s=%s' % (os.path.basename(p), h[:8])
                                       for p, h in self.good.items() if h))
        results = []
        for t in teeth:
            self.p('tooth: %s' % t.name[:90])
            r = self.run_tooth(t, observe)
            results.append(r)
            self.p('%s: witness=%s verdicts=%s%s -> %s' % (
                t.name, r['witness'], ','.join(r['verdicts']) or '-',
                ' collateral=%s' % r['coll'][:6] if r['coll'] else '',
                'OK' if r['ok'] else 'NOT OK: ' + '; '.join(r['why'])))
            self.p('  restored: identical to good = True')
        by = {r['name']: r for r in results}
        for t in teeth:
            if t.outcome != GREEN_PROOF or not by[t.name]['ok']:
                continue
            for c in t.checks:
                seen = [s for pn in self._pairs(t)
                        for k, s in by.get(pn, {'checks': []})['checks']
                        if k == _key(c) and by[pn]['ok']]
                if 'RED' not in seen:
                    by[t.name]['ok'] = False
                    by[t.name]['why'].append(
                        'its paired control for %r was not seen RED'
                        % c.inv.text()[:60])
        self.p('SUMMARY')
        for r in results:
            self.p('  %-4s %s%s' % ('ok' if r['ok'] else 'FAIL', r['name'],
                                    '' if r['ok'] else ': ' + '; '.join(
                                        r['why'])))
        good = sum(1 for r in results if r['ok'])
        self.p('%s: %d of %d teeth behaved as declared%s'
               % (self.name, good, len(results),
                  ' (%d retired, listed above)' % len(retired)
                  if retired else ''))
        return 0 if good == len(results) else 1


def run_runner(argv, name, specs, prep=None, artifacts=(), match=PREFIX,
               env=None, settle=SETTLE, out=None):
    """-> exit status. Testable: no sys.exit, no global state."""
    flags = {a for a in argv if a.startswith('--')}
    unknown = flags - {'--dry', '--observe', '--list'}
    r = Runner(name, specs, prep, artifacts, match, env, settle, out)
    try:
        if unknown:
            raise RunnerFailure('unknown option %s' % sorted(unknown))
        sel = [a for a in argv if not a.startswith('--')]
        return r.go(sel, dry='--dry' in flags, observe='--observe' in flags,
                    list_only='--list' in flags)
    except RunnerFailure as e:
        r.p('!! the runner FAILS: %s' % e)
        return 2


def main(name, specs, prep=None, artifacts=(), match=PREFIX, root=ROOT):
    os.chdir(root)
    sys.exit(run_runner(sys.argv[1:], name, specs, prep, artifacts, match,
                        Env(root)))


# ---------------------------------------------------------------------
# the self-test (L1): in-process, a fake clock, build and gates; the real
# build/emulator adapters RAISE if reached; real child processes are
# spawned only to test Invocation.run itself. Planted specs MUST fail the
# runner with the cause named; one good spec must pass.
# ---------------------------------------------------------------------
GOOD_SRC = 'A=GOOD1\nB=GOOD2\nC=GOOD3\n'
PROG = ('            lda   #1                ;GOODX in a comment\n'
        '* GOODY a star comment\n'
        '            sta   $00\n')
OTHER = 'not read by the build\n'


class FakeEnv(Env):
    """Real files in a temp dir; time, builds and gates are fake."""
    def __init__(self, root):
        super().__init__(root)
        self.now = 1000.0
        self.violations = []
        self.last_build = None
        self.builds = 0
        self.build_rc = 0
        self.mangle_after = None
        self.gates = {}
        self.ran = []
        self.writes = []

    def clock(self):
        return self.now

    def sleep(self, s):
        self.now += s

    def write(self, p, text):
        # the mtime rule, as an assertion: a write within a second of
        # the last build would be invisible to GNU make 3.81
        if self.last_build is not None and self.now - self.last_build < 1.0:
            self.violations.append((p, round(self.now - self.last_build, 2)))
        self.writes.append(p)
        super().write(p, text)

    def run(self, inv):
        self.ran.append(inv)
        cmd = inv.cmd
        if isinstance(cmd, str) and cmd.startswith('fake:'):
            r = self.gates[cmd[5:].split()[0]](self)
            return r if isinstance(r, Result) else Result('EXIT', *r)
        raise AssertionError('the self-test reached a real command: %r'
                             % (cmd,))

    def build(self, _env):
        self.builds += 1
        self.last_build = self.now
        src = self.read('src.txt')
        if self.build_rc or 'BUILDFAIL' in src:
            return self.build_rc or 1, 'make: *** [out.bin] Error 1'
        extra = 'MANGLED\n' if self.mangle_after is not None and \
            self.builds > self.mangle_after else ''
        Env.write(self, 'out.bin', 'BUILT:' + src + self.read('prog.s')
                  + extra)
        Env.write(self, 'out2.bin', 'BUILT2:' + self.read('other.txt'))
        return 0, 'built'


def _gate_rows(env):
    """R1/R2/C1 fail when BAD1/BAD2/BAD3 is in the artifact."""
    art = env.read('out.bin')
    ok, bad = [], []
    for row, marker in (('R1', 'BAD1'), ('R2', 'BAD2'), ('C1', 'BAD3')):
        (bad if marker in art else ok).append(row)
    out = ['[check-devfs] PASS %s the row: [1]' % r for r in ok]
    out.append('libc++abi: terminating due to uncaught exception of type '
               'std::__1::system_error: mutex lock failed')
    if bad:
        out.append('[check-fake] FAIL: %d row(s)' % len(bad))
        out += ['  - %s the row: got 1, want 2' % r for r in bad]
        return 1, '\n'.join(out)
    return 0, '\n'.join(out + ['[check-fake] PASS: all rows'])


def _gate_green(env):
    return 0, '\n'.join('[check-devfs] PASS %s ok' % r
                        for r in ('R1', 'R2', 'C1')) + \
        '\n[check-fake] PASS: always'


def _gate_agg(env):
    if 'BAD' in env.read('out.bin'):
        return 1, '[check-fake] FAIL: the aggregate: BAD in the artifact'
    return 0, '[check-fake] PASS: ok'


def _gate_bullets(env):
    if 'BAD1' in env.read('out.bin'):
        return 1, '  - R1 bad\n[check-fake] FAIL: 1 row(s)'
    return 0, '[check-fake] PASS: ok'


def _then(ret):
    """A gate that is green on the clean tree and returns `ret` once the
    artifact is sabotaged."""
    def gate(env):
        if 'BAD' not in env.read('out.bin'):
            return _gate_green(env)
        return ret
    return gate


def _gate_make(env):
    if 'BAD' not in env.read('out.bin'):
        return _gate_green(env)
    return 2, ('[check-devfs] PASS R2 ok\n  - R1 bad\n[check-fake] FAIL: 1 '
               'row(s)\nmake: *** [check-fake] Error 1')


def _probe(env):
    return 0, ('MUTATED' if 'BAD1' in env.read('out.bin') else 'clean')


GATES = {
    'probe': _probe, 'probe_always': lambda e: (0, 'MUTATED'),
    'rows': _gate_rows, 'green': _gate_green, 'agg': _gate_agg,
    'bullets': _gate_bullets, 'make': _gate_make,
    'partial': lambda e: (0, '[check-devfs] PASS R1 ok\n[check-devfs] PASS '
                          'R2 ok\n[check-fake] PASS: partial'),
    'silent': lambda e: (1, ''),
    'pass1': lambda e: (1, '[check-fake] PASS: ok'),
    'namerows': lambda e: (0, 'PASS shedit modes [text40]'),
    'liar': lambda e: (0, '  - R1 x\n[check-fake] FAIL: 1 row(s)'),
    'redbase': lambda e: (1, '  - R1 x\n[check-fake] FAIL: 1 row(s)'),
    'timeout': _then(Result('TIMEOUT', None, '')),
    'signal': _then(Result('SIGNAL', -9, '')),
    'traceback': _then((1, 'Traceback (most recent call last):\n  x\n'
                        '[check-fake] FAIL: 1 row(s)')),
    'norule': _then((2, "make: *** No rule to make target 'x'.  Stop.")),
    'makenofinal': _then((2, 'make: *** [check-fake] Error 1')),
}


def _world():
    root = tempfile.mkdtemp(prefix='teeth-selftest-')
    env = FakeEnv(root)
    env.write('src.txt', GOOD_SRC)
    env.write('prog.s', PROG)
    env.write('other.txt', OTHER)
    Env.write(env, 'out.bin', 'BUILT:' + GOOD_SRC + PROG)
    Env.write(env, 'out2.bin', 'BUILT2:' + OTHER)
    env.gates = dict(GATES)
    env.writes = []
    return env


def _chk(cmd='fake:rows', reporter='devfs', expect=None, **kw):
    kw.setdefault('tag', 'check-fake')
    inv = cmd if isinstance(cmd, Invocation) else Invocation(cmd)
    return Check(inv, reporter, expect or Rows(red=('R1',)), **kw)


def _tooth(name='G1 a good tooth', **kw):
    kw.setdefault('edits', [Edit('src.txt', 'GOOD1', 'BAD1')])
    kw.setdefault('checks', [_chk(expect=Rows(red=('R1',),
                                              controls=('R2', 'C1')))])
    return Tooth(name, **kw)


def _cases():
    c = []

    def add(label, teeth, want, msg='', argv=(), pre=None, post=None,
            match=PREFIX, settle=SETTLE, prep=True, art=('out.bin',)):
        c.append(dict(label=label, teeth=teeth, want=want, msg=msg,
                      argv=list(argv), pre=pre, post=post, match=match,
                      settle=settle, prep=prep, art=art))

    ed = Edit
    agg = Aggregate(r'^\[check-fake\] FAIL: the aggregate', 'no rows')
    add('good spec: control, composite checks, regex, Aggregate, 2 files',
        lambda: [_tooth(), Tooth(
            'G2 composite + regex',
            edits=[ed('src.txt', r'GOOD[23]', 'BAD2', count=2, regex=True),
                   ed('other.txt', 'not', 'NOT')],
            checks=[_chk(expect=Rows(red=('R2',), controls=('R1',))),
                    _chk('fake:agg', 'aggregate', agg)])], 0)
    add('always-green gate',
        lambda: [_tooth(checks=[_chk('fake:green')])], 1, 'stayed GREEN')
    add('ALL: a named row stays green',
        lambda: [_tooth(checks=[_chk(expect=Rows(red=('R1', 'R2')))])],
        1, 'row R2 stayed green')
    add('ANY: none of the named rows went red',
        lambda: [_tooth(checks=[_chk(expect=Rows(red=('R2', 'C1'),
                                                 rule=ANY))])],
        1, 'none of')
    add('a control goes red though the named row went red',
        lambda: [_tooth(edits=[ed('src.txt', 'GOOD1', 'BAD1'),
                               ed('src.txt', 'GOOD3', 'BAD3')],
                        checks=[_chk(expect=Rows(red=('R1',),
                                                 controls=('C1',)))])],
        1, 'control C1 went red')
    add('a control the gate never prints (the clean run)',
        lambda: [_tooth(checks=[_chk('fake:partial', expect=Rows(
            red=('R1',), controls=('C1',)))])],
        2, 'never printed a PASS row')
    add('an unobservable control is rejected by the lint',
        lambda: [_tooth(checks=[_chk('fake:bullets', 'bullets_only', Rows(
            red=('R1',), controls=('R2',)))])],
        2, 'cannot be seen to run')
    add('an unknown selector', lambda: [_tooth()], 2, 'matches no tooth',
        argv=['ZZ9'])
    add('an empty spec list', lambda: [], 2, 'declares no teeth')
    add('a missing pattern',
        lambda: [_tooth(edits=[ed('src.txt', 'NOPE', 'X')])], 2,
        'found 0 time')
    add('a pattern found twice (count=1)',
        lambda: [_tooth(edits=[ed('src.txt', 'GOOD', 'BAD')])], 2,
        'found 3 time')
    add('an edit that only matches comment text',
        lambda: [_tooth(edits=[ed('prog.s', 'GOODX in a comment', 'BAD1')])],
        2, 'only comment text')
    add('a star-comment line is comment text too',
        lambda: [_tooth(edits=[ed('prog.s', 'GOODY a star', 'BAD1')])],
        2, 'only comment text')
    add('a comment-only edit with its justification passes',
        lambda: [_tooth(edits=[ed('prog.s', 'GOODX in a comment', 'BAD1',
                                  comment_ok='the build embeds the file')])],
        0)
    add('an unchanged witness: an edit the build ignores',
        lambda: [_tooth(edits=[ed('other.txt', 'not read', 'NOT read')],
                        witness=Changed(['out.bin']))], 2, 'left')
    add('a static tooth (Unchanged) that changed the artifact',
        lambda: [_tooth(witness=Unchanged())], 2, 'was not static')
    add('witness ALL: only one of two paths moved',
        lambda: [_tooth(witness=Changed(['out.bin', 'out2.bin'],
                                        quant=ALL))],
        2, 'ALL of 2 paths', art=('out.bin', 'out2.bin'))
    add('witness ANY: one of two paths moved passes',
        lambda: [_tooth(witness=Changed(['out.bin', 'out2.bin']))], 0,
        art=('out.bin', 'out2.bin'))
    add('a failing preparation build', lambda: [_tooth()], 2,
        'canonical build failed', pre=lambda e: setattr(e, 'build_rc', 1))
    add('a failing baseline gate',
        lambda: [_tooth(checks=[_chk('fake:redbase')])], 2, 'not green')
    add('a sabotaged build that does not build',
        lambda: [_tooth(edits=[ed('src.txt', 'GOOD1', 'BUILDFAIL')])], 2,
        'sabotaged build failed')
    add('a retired tooth is listed and not run',
        lambda: [_tooth(), _tooth(name='R1 retired', retired='the code it '
                                  'sabotaged is gone', checks=[_chk(
                                      'fake:silent')])], 0,
        'RETIRED (not run): R1 retired')
    add('selecting only a retired tooth runs nothing',
        lambda: [_tooth(), _tooth(name='R1 retired', retired='gone')], 2,
        'every selected tooth is retired', argv=['R1'])
    add('--list marks a retired tooth',
        lambda: [_tooth(name='R1 retired', retired='gone')], 0,
        '[RETIRED: gone]', argv=['--list'])
    add('a retired tooth with a stale pattern does not fail the lint',
        lambda: [_tooth(), _tooth(name='R1 retired', retired='gone',
                                  edits=[ed('src.txt', 'NOPE', 'X')])],
        0, 'all apply', argv=['--dry'])
    add('a build_fail tooth that also lists checks is rejected',
        lambda: [Tooth('B1 both', edits=[ed('src.txt', 'GOOD1', 'BUILDFAIL')],
                       build_fail='Error 1', checks=[_chk()])], 2,
        'runs no checks')
    probe = Invocation('fake:probe')
    add('a mutation probe that shows the mutation passes',
        lambda: [_tooth(witness=CommandMutation('the edit', probe,
                                                r'^MUTATED'))], 0)
    add('a mutation probe with no pred is rejected (it would match all)',
        lambda: [_tooth(witness=CommandMutation('the edit', probe, ''))],
        2, 'needs a pred')
    add('a mutation probe that already matches the CLEAN tree',
        lambda: [_tooth(witness=CommandMutation(
            'the edit', Invocation('fake:probe_always'), r'^MUTATED'))],
        2, 'already matches')
    add('a mutation probe that never matches fails the tooth',
        lambda: [_tooth(witness=CommandMutation('the edit', probe,
                                                r'^NEVER'))],
        1, 'probe did not show')
    add('a tooth with its own prep and a runner with none cannot restore',
        lambda: [Tooth('F1 flag', checks=[_chk(expect=Rows(red=('R1',)))],
                       prep=Fn(lambda e: (Env.write(e, 'out.bin', 'BAD1\n')
                                          or (0, 'built'))),
                       artifacts=['out.bin'])], 2,
        'has none to put the good artifacts back', prep=False)
    add('a tooth with no edit and no prep is rejected',
        lambda: [_tooth(edits=[])], 2, 'no edits needs its own prep')
    add('a build-flag tooth: no edits, its own prep is the mutation',
        lambda: [Tooth('F1 flag', checks=[_chk(expect=Rows(red=('R1',)))],
                       prep=Fn(lambda e: (Env.write(e, 'out.bin', 'BAD1\n')
                                          or (0, 'built'))),
                       artifacts=['out.bin'])], 0,
        post=lambda e: None if e.read('out.bin') == 'BUILT:' + GOOD_SRC
        + PROG else 'out.bin left sabotaged: %r' % e.read('out.bin'))
    add('a build expected to fail does, with its marker',
        lambda: [Tooth('B1 build must fail', edits=[ed(
            'src.txt', 'GOOD1', 'BUILDFAIL')], build_fail='Error 1')], 0)
    add('a gate with no terminal verdict line',
        lambda: [_tooth(checks=[_chk('fake:silent')])], 2,
        'no complete terminal verdict')
    add('a PASS verdict with a non-zero exit status',
        lambda: [_tooth(checks=[_chk('fake:pass1')])], 2, 'exit status 1')
    add('incomplete output: a requested row is never printed',
        lambda: [_tooth(checks=[_chk(
            'fake:namerows text40 modes hist', 'namerows', Rows(
                red=('modes [text40]',)))])], 2, 'rows never printed')
    add('edits that cancel each other change no byte',
        lambda: [_tooth(edits=[ed('src.txt', 'GOOD1', 'BAD1'),
                               ed('src.txt', 'BAD1', 'GOOD1')])], 2,
        'change no byte')
    add('a build meant to fail, with the wrong marker',
        lambda: [Tooth('B1 build must fail', edits=[ed(
            'src.txt', 'GOOD1', 'BUILDFAIL')], build_fail='NOT THERE')], 2,
        'was meant to FAIL')
    add('a FAIL verdict with exit status 0',
        lambda: [_tooth(checks=[_chk('fake:liar')])], 2, 'exit status 0')
    add('a timeout is not a verdict',
        lambda: [_tooth(checks=[_chk('fake:timeout')])], 2, 'TIMEOUT')
    add('a signal death is not a verdict',
        lambda: [_tooth(checks=[_chk('fake:signal')])], 2, 'SIGNAL')
    add('a Traceback is not a verdict',
        lambda: [_tooth(checks=[_chk('fake:traceback')])], 2,
        'did not complete')
    add('a missing prerequisite is not a verdict',
        lambda: [_tooth(checks=[_chk('fake:norule')])], 2,
        'did not complete')
    add('make status 2 WITH a complete FAIL line is RED',
        lambda: [_tooth(checks=[_chk('fake:make', expect=Rows(
            red=('R1',), controls=('R2',)))])], 0)
    add('make status 2 WITHOUT a terminal line is an ERROR',
        lambda: [_tooth(checks=[_chk('fake:makenofinal')])], 2,
        'no complete terminal verdict')
    add('the libc++abi teardown line is noise, not a verdict',
        lambda: [_tooth()], 0)
    add('Aggregate: the predicate does not match the red output',
        lambda: [_tooth(checks=[_chk('fake:agg', 'aggregate', Aggregate(
            r'^NEVER SAID', 'no rows'))])], 1, 'is not in the output')
    add('Aggregate: an unanchored predicate is rejected',
        lambda: [_tooth(checks=[_chk('fake:agg', 'aggregate', Aggregate(
            r'FAIL', 'no rows'))])], 2, 'anchored')
    add('race variables in a command need race=True',
        lambda: [_tooth(checks=[_chk(Invocation(
            'fake:rows', env={'MAUX_GATE_RACE': 'early'}))])], 2,
        'race=True')
    add('the same Invocation is baselined once',
        lambda: [_tooth(), _tooth(name='G2 again')], 0,
        post=lambda e: None if sum(
            1 for i in e.ran if i.cmd == 'fake:rows') == 3
        else 'ran %d' % sum(1 for i in e.ran if i.cmd == 'fake:rows'))
    add('baselines with different fixtures are run separately',
        lambda: [_tooth(checks=[
            _chk(Invocation('fake:rows', fixture='fresh-a'),
                 expect=Rows(red=('R1',))),
            _chk(Invocation('fake:rows', fixture='fresh-b'),
                 expect=Rows(red=('R1',)))])], 0,
        post=lambda e: None if sum(
            1 for i in e.ran if i.fixture and i.cmd == 'fake:rows') == 4
        else 'fixtures ran %s' % [i.fixture for i in e.ran if i.fixture])
    add('GREEN_PROOF whose paired control is not RED',
        lambda: [Tooth('P1 proof', edits=[ed('src.txt', 'GOOD1', 'GOOD1x')],
                       checks=[_chk('fake:green', expect=Rows(
                           controls=('R1',)))],
                       outcome=GREEN_PROOF, pair='P2 control'),
                 Tooth('P2 control', edits=[ed('src.txt', 'GOOD2', 'GOOD2x')],
                       checks=[_chk('fake:green')])],
        1, 'was not seen RED', argv=['P1'])
    add('GREEN_PROOF with a RED pair passes (the pair is added)',
        lambda: [Tooth('P1 proof', edits=[ed('src.txt', 'GOOD1', 'GOOD1x')],
                       checks=[_chk(expect=Rows(controls=('R1', 'R2')))],
                       outcome=GREEN_PROOF, pair='P2 control'),
                 Tooth('P2 control', edits=[ed('src.txt', 'GOOD2', 'BAD2')],
                       checks=[_chk(expect=Rows(red=('R2',)))])],
        0, 'running both', argv=['P1'])
    add('GREEN_PROOF: a green check with no matching RED check',
        lambda: [Tooth('P1 proof', edits=[ed('src.txt', 'GOOD1', 'GOOD1x')],
                       checks=[_chk(expect=Rows(controls=('R1',))),
                               _chk('fake:agg', 'aggregate', agg)],
                       outcome=GREEN_PROOF, pair='P2 control'),
                 Tooth('P2 control', edits=[ed('src.txt', 'GOOD2', 'BAD2')],
                       checks=[_chk(expect=Rows(red=('R2',)))])],
        2, 'no matching RED check')
    add('GREEN_EQUIVALENT: a mutant the gate rightly accepts',
        lambda: [Tooth('E1 equiv', edits=[ed('src.txt', 'GOOD1', 'GOOD1x')],
                       checks=[_chk(expect=Rows(controls=('R1',)))],
                       outcome=GREEN_EQUIVALENT)], 0)
    add('a Python-tool tooth: no build, SourceOnly',
        lambda: [Tooth('T1 tool', edits=[ed('other.txt', 'not', 'NOT')],
                       checks=[_chk('fake:agg', 'aggregate', Aggregate(
                           r'^NEVERMATCHES', 'no rows'))],
                       witness=SourceOnly(), outcome=GREEN_EQUIVALENT)],
        0, prep=False, art=())
    add('a restore whose rebuild drifts',
        lambda: [_tooth()], 2, 'not the good',
        pre=lambda e: setattr(e, 'mangle_after', 3))
    add('a non-deterministic path is excused by its reason',
        lambda: [_tooth(artifacts=[Path('out.bin', False, 'regenerated')])],
        0, pre=lambda e: setattr(e, 'mangle_after', 3))
    add('a write inside the settle window (settle=0 shows the check)',
        lambda: [_tooth(), _tooth(name='G2 again')], 0, 'VIOLATIONS',
        settle=0.0)
    add('a multi-file tooth with a stale 2nd edit writes nothing',
        lambda: [_tooth(edits=[ed('src.txt', 'GOOD1', 'BAD1'),
                               ed('other.txt', 'NOPE', 'X')])], 2,
        'found 0 time', post=lambda e: None if not e.writes
        else 'wrote %s' % e.writes)
    add('--dry is static: nothing is built, run or written',
        lambda: [_tooth()], 0, 'all apply', argv=['--dry'],
        post=lambda e: None if not e.ran and e.builds == 0 and not e.writes
        else 'dry touched %s %s %s' % (e.ran, e.builds, e.writes))
    add('--dry reports a stale pattern',
        lambda: [_tooth(edits=[ed('src.txt', 'NOPE', 'X')])], 2,
        'found 0 time', argv=['--dry'])
    add('SUBSTRING selector', lambda: [_tooth()], 0, '1 of 1',
        argv=['good'], match=SUBSTRING)
    return c


#: genuine excerpts of each gate's output (audit logs, 2026-10-23): the
#: grammar each reporter must keep reading. (reporter, tag, cmd, rc, output,
#: terminal, {row: verdict})
FIXTURES = [
    ('devfs', 'check-shnlvar', 'make check-shnlvar', 2,
     "[check-carrier] PASS: vendor/prodos-basic.po matches the lock\n"
     "[check-devfs] PASS N1b ( ) unquoted: L1 L2 L3: ['L1 L2 L3']\n"
     "[check-shnlvar] FAIL: 2 row(s)\n"
     "  - N7a ( ) accepted at 249: got ['sh: $(): cannot pass variables']\n"
     "libc++abi: terminating due to uncaught exception of type std::__1::"
     "system_error: mutex lock failed: Invalid argument\n",
     'FAIL', {'N1b': 'PASS', 'N7a': 'FAIL', 'vendor/prodos-basic.po': None}),
    ('devfs', 'check-shmlquote', 'python3 scripts/check_shmlquote.py', 1,
     "[check-shmlquote] FAIL: 1 row(s)\n"
     "  - console hist: R2: never saw a bare '$'; glass:\n",
     'FAIL', {'R2': 'FAIL'}),
    ('tagged', 'check-oappend', 'python3 scripts/check_oappend.py solo two',
     1, "  - solo: the mark after two appends is EOF 10: 1\n"
        "[check-oappend] solo: FAIL\n"
        "[check-oappend] two: file is 320 bytes (want 646)\n"
        "  - two: length 320 want 646\n[check-oappend] two: FAIL\n"
        "[check-oappend] FAIL: 2 row(s)\n",
     'FAIL', {'solo': 'FAIL', 'two': 'FAIL'}),
    ('tagged', 'check-oappend-sh', 'python3 scripts/check_oappend_sh.py A1e',
     1, "[check-oappend-sh] A1e: FAIL\n[check-oappend-sh] FAIL: 3 problem(s)\n",
     'FAIL', {'A1e': 'FAIL'}),
    ('bullets_only', 'check-shmlquote',
     'python3 scripts/check_shmlquote.py --part b --rows hist', 1,
     "[check-shmlquote] FAIL: 1 row(s)\n"
     "  - console hist: R2: never saw a bare '$'; glass:\n",
     'FAIL', {'R2': 'FAIL', 'console': None}),
    ('ascore', None, 'python3 scripts/check_ascore.py --image x', 1,
     "[check-ascore] FAIL: (e) DSK dispatch alive\n"
     "[check-ascore] FAIL: ASEXIT no exit redirect\n",
     'FAIL', {'(e)': 'FAIL', 'ASEXIT': 'FAIL'}),
    ('tagged', 'check-oappend-sh', 'python3 scripts/check_oappend_sh.py A1',
     0, "[check-oappend-sh] A1: PASS\n[check-oappend-sh] PASS (12 s)\n",
     'PASS', {'A1': 'PASS'}),
    ('bullets_only', 'check-openrw', 'python3 scripts/check_openrw.py R3', 1,
     "[check-openrw] R3 exec 3>F: refused after ~220000 cycles\n"
     "[check-openrw] FAIL: 2 problem(s)\n"
     "  - R3 exec 3>F; echo x >> F: retry counter 0, want the bound 30\n",
     'FAIL', {'R3': 'FAIL'}),
    ('bullets_only', 'check-open-census', 'python3 scripts/check_open_census.py',
     1, "[check-open-census] FAIL: 1 problem(s)\n"
        "  - src/bin/tee.s:163: census says OPARM is append but ..\n",
     'FAIL', {'src/bin/tee.s': 'FAIL'}),
    ('namerows', None, 'python3 scripts/check_shedit.py text40 modes', 1,
     'FAIL shedit modes [text40]\n(the error text)\n',
     'FAIL', {'modes [text40]': 'FAIL'}),
    ('namerows', None, 'python3 scripts/check_tabcomp.py text40 cmd', 0,
     'PASS tabcomp cmd [text40]\n', 'PASS', {'cmd [text40]': 'PASS'}),
    ('sleep', None, 'python3 scripts/check_sleep.py --only wrap', 1,
     "[check-sleep] FAIL wrap: wrapped sleep entered 1 times\n"
     "[check-sleep] FAIL: wrap\n", 'FAIL', {'wrap': 'FAIL'}),
    ('wait', None, 'make check-wait', 2,
     "[check-wait] census: FAIL: census\n[check-wait] fork: PASS\n"
     "[check-wait] VIOLATION: contract @cycle 5\n"
     "[check-wait] FAIL: rows failed: census\n",
     'FAIL', {'census': 'FAIL', 'fork': 'PASS'}),
    ('ascore', None, 'python3 scripts/check_ascore.py --image x', 1,
     "[check-ascore] FAIL: (c) symtab in aux: expected P1\n",
     'FAIL', {'(c)': 'FAIL'}),
    ('jobctl', 'check-jobctl-a', 'make check-jobctl-a', 2,
     "[check-jobctl-a] ok   bg_survives\n"
     "[check-jobctl-a] FAIL script_whole: timed out\n"
     "[check-jobctl-a] FAIL: 1 of 12 cases\n",
     'FAIL', {'bg_survives': 'PASS', 'script_whole': 'FAIL'}),
    ('aggregate', 'check-jobctl-b', 'make check-jobctl-b', 2,
     "[check-jobctl-b] ok   stop   (JC STOP pid=05)\n"
     "[check-jobctl-b] FAIL: tcsub: the child is ZOMBIE after ^C\n",
     'FAIL', {}),
    ('fdact', None, 'python3 scripts/check_fdact.py build/fdatest.po', 1,
     "[check-fdact] PASS: LZ_WANT is clear at the start\n"
     "[check-fdact] FAIL: B0  DUP 4<-5 (fd 5 closed)  K1 -> $00\n",
     'FAIL', {}),
    ('fdact', None, 'python3 scripts/check_fdact.py build/fdatest.po', 0,
     "[check-fdact] PASS: K5 the positives left no bank or reference "
     "behind\n", 'PASS', {}),
    ('demo', None, 'python3 scripts/demo_record.py site/demos/mygrep.py', 1,
     "FAIL mygrep (gate mode): grep prints the same rows: the echo\n",
     'FAIL', {}),
    ('recorder', None, 'python3 scripts/check_recorder.py', 1,
     "PASS  mygrep passes in gate mode  (8 checks)\n"
     "FAIL  PNG decoder round-trips all five row filters\n      detail\n"
     "check-recorder: 1 of 24 rows FAILED\n", 'FAIL',
     {'mygrep passes in gate mode': 'PASS',
      'PNG decoder round-trips all five row filters': 'FAIL'}),
    ('assertion', 'check-more', 'make check-more', 2,
     "Traceback (most recent call last):\n  File \"a.py\", line 3\n"
     "AssertionError: timed out waiting for pipe: first screen; screen:\n"
     "make: *** [check-more] Error 1\n", 'FAIL', {}),
    ('aggregate', 're:check-shlang(?:-[a-z]+)?', 'make check-shlang', 2,
     "[check-shlang] PASS: stage one\n[check-shlang-hd] PASS: stage two\n"
     "[check-shlang-b] FAIL: RESULTS expected b'x'\nmake: *** Error 1\n",
     'FAIL', {}),
    ('aggregate', 're:check-shlang(?:-[a-z]+)?', 'make check-shlang', 0,
     "[check-shlang] PASS: stage one\n[check-shlang-b] PASS: stage two\n",
     'PASS', {}),
    ('assertion', 'check-play', 'make check-play', 2,
     "Traceback (most recent call last):\n  File \"a.py\", line 3\n"
     "RuntimeError: timed out waiting for shell prompt; screen was:\n"
     "make: *** [check-play] Error 1\n", 'FAIL', {}),
    ('assertion', 'check-play', 'make check-play', 1,
     "[check-play] FAIL: splash text left on tty screen\n", 'FAIL', {}),
    ('assertion', 'check-play', 'make check-play', 2,
     "Traceback (most recent call last):\n  File \"a.py\", line 3\n"
     "RuntimeError: something else\n", None, {}),
    ('assertion', 'check-more', 'make check-more', 2,
     "Traceback (most recent call last):\n  File \"a.py\", line 3\n"
     "KeyError: 'x'\n", None, {}),
]


def _reporter_fixtures():
    fails = []
    for rep, tag, cmd, rc, out, term, rows in FIXTURES:
        par = REPORTERS[rep].parse(out, rc, tag or tag_of(cmd), cmd)
        got = {k: par.rows.get(k) for k in rows}
        if par.terminal != term or got != rows:
            fails.append(('reporter %s reads a real %s output' % (rep, cmd),
                          0, 0, 'terminal %r rows %r, wanted %r %r'
                          % (par.terminal, got, term, rows)))
    return fails


def selftest():
    fails = []
    t0 = time.time()
    n = 0
    for k in _cases():
        n += 1
        env = _world()
        if k['pre']:
            k['pre'](env)
        buf = io.StringIO()
        try:
            prep = Fn(env.build) if k['prep'] else None
            with redirect_stdout(buf):
                rc = run_runner(k['argv'], 'selftest', k['teeth'](), prep,
                                k['art'], k['match'], env, k['settle'],
                                out=lambda s: print(s))
            text = buf.getvalue()
            if k['msg'] == 'VIOLATIONS':
                ok = rc == k['want'] and bool(env.violations)
            else:
                ok = rc == k['want'] and k['msg'] in text
                if env.violations and k['settle']:
                    ok, text = False, text + '\nmtime violations %s' \
                        % env.violations
            if k['post']:
                err = k['post'](env)
                if err:
                    ok, text = False, text + '\n' + err
            if (env.read('src.txt'), env.read('prog.s'),
                    env.read('other.txt')) != (GOOD_SRC, PROG, OTHER):
                ok, text = False, text + '\nSOURCE NOT RESTORED'
        except Exception as e:                        # a library bug
            ok, rc, text = False, -1, '%s: %s' % (type(e).__name__, e)
        finally:
            shutil.rmtree(env.root, ignore_errors=True)
        if not ok:
            fails.append((k['label'], k['want'], rc, text[-500:]))
    # run_tooth checks the pattern count itself, not only the lint
    n += 1
    env = _world()
    r = Runner('selftest', [_tooth()], Fn(env.build), ('out.bin',),
               env=env, out=lambda s: None)
    r.good = r._snap(['out.bin'])
    try:
        r.run_tooth(_tooth(edits=[Edit('src.txt', 'GOOD', 'BAD')]))
        fails.append(('run_tooth must refuse a pattern found 3 times', 2,
                      0, ''))
    except RunnerFailure:
        pass
    shutil.rmtree(env.root, ignore_errors=True)
    # a pre-existing uncommitted edit in a touched file must survive
    n += 1
    env = _world()
    env.write('src.txt', GOOD_SRC + 'D=GOOD4\n')
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = run_runner([], 'selftest', [_tooth()], Fn(env.build),
                        ('out.bin',), PREFIX, env, SETTLE,
                        out=lambda s: print(s))
    if rc != 0 or env.read('src.txt') != GOOD_SRC + 'D=GOOD4\n':
        fails.append(('a pre-existing uncommitted edit must survive', 0,
                      rc, buf.getvalue()[-300:]))
    shutil.rmtree(env.root, ignore_errors=True)
    # the atomic write keeps the file mode
    n += 1
    env = _world()
    path = os.path.join(env.root, 'tool.sh')
    with open(path, 'w') as f:
        f.write('x\n')
    os.chmod(path, 0o755)
    Env.write(env, 'tool.sh', 'y\n')
    if os.stat(path).st_mode & 0o777 != 0o755:
        fails.append(('an edit keeps the file mode', 0, 0, ''))
    shutil.rmtree(env.root, ignore_errors=True)
    # the real build adapters must not run in a self-test
    n += 1
    env = _world()
    try:
        Make('x').run(env)
        fails.append(('Make must raise in the self-test', 2, 0, ''))
    except AssertionError:
        pass
    shutil.rmtree(env.root, ignore_errors=True)
    # the real Invocation.run: clean env, timeout + group kill, signal
    n += 1
    fails += _real_spawns()
    # every reporter reads a genuine excerpt of its gate
    n += 1
    fails += _reporter_fixtures()
    dt = time.time() - t0
    if fails:
        for label, want, rc, text in fails:
            print('FAIL selftest: %s (wanted exit %s, got %s)\n%s'
                  % (label, want, rc, text))
        print('teeth_lib selftest: %d of %d cases FAILED' % (len(fails), n))
        return 1
    if dt >= 2.0:
        print('teeth_lib selftest: too slow (%.2f s, budget 2 s)' % dt)
        return 1
    print('teeth_lib selftest: PASS (%d cases, %.2f s)' % (n, dt))
    return 0


def _real_spawns():
    fails = []
    root = tempfile.mkdtemp(prefix='teeth-spawn-')
    env = Env(root)
    pidf = os.path.join(root, 'grandchild.pid')
    py = sys.executable
    os.environ['MAUX_GATE_RACE'] = 'early'
    try:
        r = env.run(Invocation((py, '-c', 'import os; '
                               'print(os.environ.get("MAUX_GATE_RACE"))')))
        if r.out.strip() != 'None':
            fails.append(('the clean environment unsets MAUX_GATE_RACE', 0,
                          r.rc, r.out))
        r = env.run(Invocation((py, '-c', 'import os; print(os.environ'
                                '["MAUX_GATE_RACE"])'),
                               env={'MAUX_GATE_RACE': 'late'}))
        if r.out.strip() != 'late':
            fails.append(('an explicit env value is applied', 0, r.rc,
                          r.out))
    finally:
        del os.environ['MAUX_GATE_RACE']
    # the grandchild IGNORES TERM and has closed its stdio: after the
    # parent dies communicate() returns, and only an unconditional KILL
    # of the group reaches it (reproduced against the first version)
    gk = ('import os,signal,time; signal.signal(signal.SIGTERM,'
          'signal.SIG_IGN); [os.close(i) for i in (0,1,2)]; '
          'open(%r,"w").write(str(os.getpid())); time.sleep(30)' % pidf)
    kid = ('import subprocess,sys,time; '
           'subprocess.Popen([sys.executable,"-c",%r]); time.sleep(30)' % gk)
    r = env.run(Invocation((py, '-c', kid), timeout=0.5))
    if r.status != 'TIMEOUT':
        fails.append(('a timeout is reported as TIMEOUT', 0, r.status, ''))
    try:
        pid = int(open(pidf).read())
        alive = True
        for _ in range(20):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                alive = False
                break
            time.sleep(0.05)
        if alive:
            fails.append(('the whole process group is killed on a timeout',
                          0, pid, 'the grandchild is alive'))
            os.kill(pid, signal.SIGKILL)
    except (OSError, ValueError):
        fails.append(('the grandchild never started', 0, 0, ''))
    r = env.run(Invocation((py, '-c', 'import sys; '
                           'sys.stdout.write("listing"); sys.stdout.flush(); '
                           'sys.stderr.write("[t] FAIL: z\\n")')))
    if not re.search(r'^\[t\] FAIL: z', r.out, re.M):
        fails.append(('a stderr line is not glued to a stdout line that '
                      'has no newline', 0, r.rc, r.out))
    r = env.run(Invocation((py, '-c', 'import os,signal; '
                            'os.kill(os.getpid(), signal.SIGKILL)')))
    if r.status != 'SIGNAL':
        fails.append(('a signal death is reported as SIGNAL', 0, r.status,
                      ''))
    shutil.rmtree(root, ignore_errors=True)
    return fails


def selftest_mtime():
    """By hand, once: the REAL wait against a real `make`. With SETTLE
    the sabotaged build differs and the restore is reproduced; with
    settle=0 a make that compares whole seconds (3.81) must trip the
    witness, which is the failure the wait exists for."""
    ver = subprocess.run(['make', '--version'], capture_output=True,
                         text=True).stdout.splitlines()[0]
    print('make:', ver)
    out = {}
    for settle in (SETTLE, 0.0):
        root = tempfile.mkdtemp(prefix='teeth-mtime-')
        try:
            with open(os.path.join(root, 'Makefile'), 'w') as f:
                f.write('out: src\n\tcp src out\n')
            with open(os.path.join(root, 'src'), 'w') as f:
                f.write('GOOD\n')
            gate = Check(Invocation(
                'if grep -q BAD out; then echo "  - R1 x"; echo '
                '"[check-x] FAIL: 1 row(s)"; exit 1; else echo '
                '"[check-x] PASS: ok"; fi'), 'bullets_only',
                Rows(red=('R1',)), tag='check-x')
            t = Tooth('M1 mtime', edits=[Edit('src', 'GOOD', 'BAD')],
                      checks=[gate], witness=Changed(['out']))
            buf = io.StringIO()
            with redirect_stdout(buf):
                # the negative control must not delete the artifact (that
                # alone defeats the mtime comparison): declare none
                rc = run_runner([], 'mtime', [t], Make('out'),
                                ('out',) if settle else (), PREFIX,
                                Env(root), settle, out=lambda s: print(s))
            out[settle] = rc
            print('settle=%s -> exit %d' % (settle, rc))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    if out[SETTLE] != 0:
        print('FAIL: the library wait did not give a clean run')
        return 1
    if out[0.0] == 0:
        print('note: this make saw the sub-second edit; the negative '
              'control (settle=0) is not informative here')
    else:
        print('the negative control tripped, as GNU make 3.81 should')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        sys.exit(selftest())
    if sys.argv[1:] == ['--selftest-mtime']:
        sys.exit(selftest_mtime())
    print(__doc__)
    sys.exit(2)
