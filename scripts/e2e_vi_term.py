#!/usr/bin/env python3
"""e2e_vi_term.py -- person-like end-to-end tests for the maux terminal
and vi, on every console backend (40-col, native-80, UltraTerm).

Uses e2e_term.Term: one key at a time, the guest free-running a jittered
slice between keys, asserting on what is actually RENDERED and ECHOED --
the way a person operates the machine. Each case is exactly a thing a
human does at the keyboard; the assertions are what they would see.

Cases:
  shell_echo   type `echo <MARK>` at the prompt char-by-char: it ECHOES,
               runs, prints <MARK>.
  vi_insert    `vi f`, i, type text (echoes as you type), ESC, `:q!`.
  suspend_echo `vi f`, i, text, ESC, ^Z -> at the shell, type a command:
               IT MUST ECHO (the dead-echo bug's exact shape), then `fg`
               back into vi.
  nesting_edit vi#1, edit, ^Z; vi#2, edit (echoes), ESC, more mode
               toggling; ^Z; `fg`. The editor must stay RESPONSIVE
               throughout -- the reported wedge lives here.
  shellout     `vi f`, `:!echo <MARK>`: the child output shows, the
               [Hit return] prompt appears, RETURN repaints, vi is alive.

Run: python3 e2e_vi_term.py [text40|text80|ut|all]
"""
import re
import sys

import e2e_term as E

MARK = 'E2EMARK'


def case_shell_echo(t):
    t.run_cmd_echoed('echo ' + MARK, 'shell_echo')
    t.wait(MARK, 'shell_echo: output')


def case_vi_insert(t):
    t.run_cmd_echoed('vi e2f', 'vi_insert: launch')
    t.wait('~', 'vi_insert: vi up (tildes)')
    t.press('i')
    t.type_and_expect_echo('HELLO', 'vi_insert: inserted text echoes')
    t.press(E.Term.ESC)
    t.type_human(':q!')
    t.enter()
    t.wait('$', 'vi_insert: back at the shell')


def case_suspend_echo(t):
    t.run_cmd_echoed('vi e2s', 'suspend_echo: launch')
    t.wait('~', 'suspend_echo: vi up')
    t.press('i')
    t.type_and_expect_echo('SUSPMEE', 'suspend_echo: insert echoes')
    t.press(E.Term.ESC)
    t.press(E.Term.CTRL_Z)
    t.wait('Stopped', 'suspend_echo: ^Z reports Stopped')
    # THE BUG THE OLD HARNESS MISSED: once the prompt is back, is the
    # shell in cooked+echo? run_cmd_echoed waits for the settled prompt
    # (like a person) then requires the typed command to echo.
    t.run_cmd_echoed('echo BACKHERE', 'suspend_echo: shell echoes after ^Z')
    t.wait('BACKHERE', 'suspend_echo: command ran')
    t.run_cmd_echoed('fg', 'suspend_echo: fg')
    t.wait('~', 'suspend_echo: fg redraws vi')
    t.press('x')                       # editable again?
    t.type_human(':q!')
    t.enter()
    t.wait('$', 'suspend_echo: quit back to shell')


def case_nesting_edit(t):
    t.run_cmd_echoed('vi e2n1', 'nesting: vi#1 launch')
    t.wait('~', 'nesting: vi#1 up')
    t.press('i')
    t.type_and_expect_echo('ONEONE', 'nesting: vi#1 insert echoes')
    t.press(E.Term.ESC)
    t.press(E.Term.CTRL_Z)
    t.wait('Stopped', 'nesting: vi#1 ^Z')
    t.run_cmd_echoed('echo MID', 'nesting: shell echoes between')
    t.wait('MID', 'nesting: shell ran between')
    t.run_cmd_echoed('vi e2n2', 'nesting: vi#2 launch')
    t.wait('~', 'nesting: vi#2 up')
    # Hammer insert/command toggling in vi#2 -- the reported wedge point.
    for n in range(12):
        t.press('i')
        t.type_and_expect_echo(f'X{n}', f'nesting: vi#2 insert {n} echoes')
        t.press(E.Term.ESC)
        t.press('0')                   # motion in command mode
    # still responsive?
    t.press('i')
    t.type_and_expect_echo('ALIVE', 'nesting: vi#2 still responsive')
    t.press(E.Term.ESC)
    t.press(E.Term.CTRL_Z)
    t.wait('Stopped', 'nesting: vi#2 ^Z')
    t.run_cmd_echoed('echo NEST', 'nesting: shell echoes after vi#2 ^Z')
    t.wait('NEST', 'nesting: shell ran after vi#2 ^Z')


def case_shellout(t):
    t.run_cmd_echoed('vi e2o', 'shellout: launch')
    t.wait('~', 'shellout: vi up')
    t.type_human(':!echo ' + MARK)
    t.enter()
    t.wait(MARK, 'shellout: child output visible')
    t.wait('return', 'shellout: [Hit return] prompt')
    t.enter()
    t.wait('~', 'shellout: repaint after RETURN')
    t.type_human(':q!')
    t.enter()
    t.wait('$', 'shellout: back at the shell')


def case_wedge_hunt(t):
    """Mirror the operator's exact repro as closely as possible and
    hammer mode-switching in the SECOND vi, hunting the reported wedge.
    Fast typist: small between-key slices so keys land at many offsets
    relative to the scheduler tick."""
    import e2e_term as _E
    t.rng.seed(t.rng.randint(0, 1 << 30))          # vary within the run
    t.run_cmd_echoed('vi ffs', 'hunt: vi#1 launch')
    t.wait('~', 'hunt: vi#1 up')
    t.press('i')
    t.type_human("it's easy to reproduce")
    t.press(_E.Term.ESC)
    t.press(_E.Term.CTRL_Z)
    t.wait('Stopped', 'hunt: vi#1 ^Z')
    t.run_cmd_echoed('vi ffs2', 'hunt: vi#2 launch')
    t.wait('~', 'hunt: vi#2 up')
    # Realistic FAST-TYPIST speed (~30-90 ms/key = 30k-90k cyc), not the
    # superhuman 2k that just overruns the latch.
    for n in range(80):                             # hammer i/ESC
        t.press('i', cyc=t.rng.randint(30_000, 90_000))
        t.press(chr(ord('a') + (n % 26)), cyc=t.rng.randint(30_000, 90_000))
        t.press(_E.Term.ESC, cyc=t.rng.randint(30_000, 90_000))
        t.press('0', cyc=t.rng.randint(30_000, 90_000))
    # DRAIN: let the guest catch up on any queued input, no new keys.
    for _ in range(20):
        t._slice(200_000)
    # Responsiveness on a FRESH line (not the full row we just filled):
    # ESC to command mode, `o` opens a new line, type a marker, settle
    # generously, and require it to show. Dead => a real hang.
    t.press(_E.Term.ESC)
    t.press('o')
    t.type_human('ALIVE9')
    t.press(_E.Term.ESC)
    for _ in range(10):
        t._slice(200_000)
    if not t.visible('ALIVE9'):
        raise AssertionError('hunt: vi#2 did not accept a fresh-line edit '
                             'after the toggle storm -- a real wedge:\n' +
                             '\n'.join(r.rstrip() for r in t.screen()
                                       if r.strip()))


def case_insert_erase(t):
    """The operator's keystrokes of 2026-09-10, one key at a time: type,
    left-arrow (the //e's backspace key) a few times, Enter, type more.
    The erase must show live, Enter must open a line, the text after it
    must echo. Before the fix the arrow's ESC ended the insert and the
    Enter ran as a command-mode key."""
    t.run_cmd_echoed('vi e2b', 'insert_erase: launch')
    t.wait('~', 'insert_erase: vi up')
    t.press('i')
    t.type_and_expect_echo('ABCDEFG', 'insert_erase: text echoes')
    for _ in range(3):
        t.press('\x08')                   # left-arrow
    t.wait_gone('ABCDE', 'insert_erase: three left-arrows erased EFG')
    t.enter()
    t.type_and_expect_echo('NEXT', 'insert_erase: text after Enter echoes')
    t.press(E.Term.ESC)
    t.wait('ABCD', 'insert_erase: first line kept ABCD')
    t.wait('NEXT', 'insert_erase: Enter opened a line')
    t.type_human(':q!')
    t.enter()
    t.wait('$', 'insert_erase: back at the shell')


def case_scroll(t):
    """Scroll a long file the way a person does -- hold `j` to read down
    past the bottom, then `k` to read back up -- one key at a time, the
    guest free-running a jittered slice between each, asserting the
    RENDERED screen. This is the person-like check the partial scroll
    (ESC[nS / ESC[nT, 2026-09-10) needs: a stale or mis-shifted scroll
    shows the wrong line, which the burst-style check-vi cases could
    miss. DEMO/LONG is L01..L60.

    Forward: `j` past the bottom row scrolls the window up a line at a
    time, so a line from below the first screenful (L30) must come into
    view and L01 must leave the top. Reverse: `k` back to the top
    brings L01 back. Exercises both scroll directions on every backend.
    """
    t.run_cmd_echoed('vi demo/long', 'scroll: launch')
    t.wait('L01', 'scroll: vi up, L01 at the top')
    for _ in range(30):                    # read DOWN, one `j` at a time
        t.press('j')
    t.wait('L30', 'scroll: j scrolled down -- L30 now on the glass')
    t.wait_gone('L01', 'scroll: L01 scrolled off the top')
    for _ in range(30):                    # read back UP, one `k` at a time
        t.press('k')
    t.wait('L01', 'scroll-up: k scrolled back -- L01 on the glass again')
    t.wait_gone('L30', 'scroll-up: L30 scrolled off the bottom')
    t.type_human(':q!')
    t.enter()
    t.wait('$', 'scroll: back at the shell')


def case_shloop_console(t):
    """`for`/`while` typed AT THE CONSOLE (docs/SH-FEATURES.md,
    2026-09-15 console-loop spooling): CUR_IN_FD is the tty, so
    RW_FOR/RW_LOOP_PUSH cannot seek back to replay a body -- before
    this feature the one-liner printed nothing and the multi-line
    form refused with "stdin not seekable". SPOOL_ENTER copies the
    whole construct into a per-process temp file and `.`-sources it
    instead, so every scenario below actually reruns the body.

    Every output word below is Q/R/T/N-PREFIXED so it cannot be
    confused with the typed command's own echo, which already
    contains the bare loop-variable values as substrings on the
    SAME row. One session, several scenarios in a row: (a) one-
    line FOR, (b) the same across four lines with `> ` prompts,
    (c) WHILE with an `expr` counter, (d) FOR nested in FOR,
    (e) a variable set inside the loop read back after, (f) a
    glob word list, (h) a DOUBLE-quoted word in the body,
    (i) a `;` INSIDE single quotes on a body line (SPOOL_SPLIT's
    own quote tracking -- verified against the SCRIPT-FILE oracle
    by hand), (g) the leftover-spool-file check -- SH_EOF's own
    unlink-on-pop (shlex.s) must have deleted every one of them
    by then, (j) a quote BEFORE the loop on its own line refused
    loudly rather than spooled shifted, and (k) `exit` inside a
    spooled loop (from a child `SH`, so it returns here) leaking
    nothing -- SH_EXIT's own cleanup (shtrap.s).

    2026-09-15 (second review): a spooled loop-back used to
    re-enter MAINLOOP once per iteration and print ANOTHER bare
    `$ ` each time (the same prompt-print path an interactive `.`
    source also hit) -- on the 40-col backend that noise
    accumulated across several loops in one session until a later
    long command WRAPPED onto a second row, and an echo check that
    requires the whole string on ONE row (Term.visible is per-row)
    would then fail on wrapping alone, not on a real echo bug. That
    was the reason every scenario here used `type_human` instead of
    `run_cmd_echoed`. Fixed at the source (MAINLOOP, shlex.s): the
    prompt now also gates on SRC_DEPTH==0 (no sourced file, spooled
    or plain `.`, on SRC_STACK), so a spooled loop runs SILENTLY and
    the prompt reappears exactly once, when SH_EOF pops back to the
    console. Scenario (a) is typed with `run_cmd_echoed` now that
    the workaround is gone, with a teeth assertion for the fix
    itself (below). The rest still use `type_human`, one line at a
    time, because they are themselves MULTI-LINE input needing each
    continuation's own `> ` secondary prompt waited on before the
    next line is typed -- not because of any surviving wrap risk.
    The per-key echo path is proven elsewhere (case_shell_echo,
    case_vi_insert, ...); what THESE cases must prove is that the
    loop actually ran, which the output/prompt waits below already
    do.
    """
    # (a) the one-line form -- head, body and DONE all on one
    # physical line, so SPOOL_ENTER's own head-line scan already
    # closes the construct without reading anything more.
    # `run_cmd_echoed`, not the `type_human` workaround the rest of
    # this case still needs (see docstring): the stray "$ " that
    # workaround existed for is gone.
    t.run_cmd_echoed('FOR I IN AA BB CC ; DO ECHO Q$I ; DONE',
                      'shloop: one-line FOR')
    t.wait('QAA', 'shloop: one-line FOR iteration 1')
    t.wait('QBB', 'shloop: one-line FOR iteration 2')
    t.wait('QCC', 'shloop: one-line FOR iteration 3')
    t.wait_prompt('shloop: one-line FOR settled')

    # Structural check: QAA/QBB/QCC are three CONSECUTIVE rows on
    # the glass, no prompt row between them. Find QAA's row and
    # require the next two rows to be QBB then QCC.
    rows = [r.rstrip() for r in t.screen()]
    try:
        qaa_idx = next(i for i, r in enumerate(rows) if 'QAA' in r)
    except StopIteration:
        raise AssertionError(
            'shloop: QAA row not found on screen:\n' +
            '\n'.join(r for r in rows if r.strip()))
    nxt = rows[qaa_idx + 1:qaa_idx + 3]
    if len(nxt) < 2 or 'QBB' not in nxt[0] or 'QCC' not in nxt[1]:
        raise AssertionError(
            'shloop: expected QAA/QBB/QCC as three CONSECUTIVE '
            'rows with no stray prompt row between them (MAINLOOP '
            'prompt gate, shlex.s); saw:\n' +
            '\n'.join(r for r in rows if r.strip()))

    # The ACTUAL teeth for the MAINLOOP prompt-gate fix, found by
    # sabotaging it by hand: this shell's stderr write does not
    # interleave a suppressed-until-now "$ " row-by-row between
    # QAA/QBB/QCC (those stayed clean and consecutive even under
    # sabotage -- the check above alone does NOT catch this bug).
    # Every line MAINLOOP reads while replaying the spool file (the
    # head/DO lines once, the body/DONE lines once per iteration)
    # prints its own "$ " with no newline, and with nothing else
    # writing a newline in between, they all land on the SAME row
    # -- the one the real settled prompt belongs on -- once that
    # row is finally drawn. A clean settled prompt is bare "$"; with
    # the SRC_DEPTH gate removed it reads "$ $ $ $ $ $ $ $ $ $ $ $
    # $ $" (14 stray prints, confirmed by hand against this exact
    # sabotage). That row's CONTENT, not its position relative to
    # QAA/QBB/QCC, is the real tripwire.
    settled = [r.strip() for r in t.screen() if r.strip()][-1]
    if settled != '$':
        raise AssertionError(
            f'shloop: settled prompt row was {settled!r}, not a '
            f'clean "$" -- stray prompts leaked from the spooled '
            f'replay (MAINLOOP prompt gate, shlex.s); screen:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))

    # (b) the SAME shape typed across four separate lines -- each
    # continuation must show the `> ` secondary prompt, matching
    # the shape the shell's own `$ ` prompt already uses.
    t.type_human('FOR I IN PP QQ')
    t.enter()
    t.wait('> ', 'shloop: secondary prompt after FOR')
    t.type_human('DO')
    t.enter()
    t.wait('> ', 'shloop: secondary prompt after DO')
    t.type_human('ECHO R$I')
    t.enter()
    t.wait('> ', 'shloop: secondary prompt after body')
    t.type_human('DONE')
    t.enter()
    t.wait('RPP', 'shloop: multi-line iteration 1')
    t.wait('RQQ', 'shloop: multi-line iteration 2')
    t.wait_prompt('shloop: multi-line settled')

    # (c) WHILE, one line, an EXPR-driven counter -- the shape
    # docs/SH-FEATURES.md's console-loop section names by hand.
    t.type_human('N=0 ; WHILE TEST $N -lt 3 ; DO ECHO T$N ; '
                  'N=$(EXPR $N + 1) ; DONE')
    t.enter()
    t.wait('T0', 'shloop: WHILE iteration 0')
    t.wait('T1', 'shloop: WHILE iteration 1')
    t.wait('T2', 'shloop: WHILE iteration 2')
    t.wait_prompt('shloop: WHILE settled')

    # (d) a FOR nested inside a FOR, six lines -- proves SPOOL_SCAN
    # tracks DEPTH, not just "the next reserved word", and that the
    # inner loop replays through the ordinary seek machinery once
    # CUR_IN_FD is the (now seekable) spool file.
    for line in ('FOR I IN X Y', 'DO', 'FOR J IN 1 2', 'DO',
                 'ECHO N$I-$J', 'DONE', 'DONE'):
        t.type_human(line)
        t.enter()
    t.wait('NX-1', 'shloop: nested X-1')
    t.wait('NX-2', 'shloop: nested X-2')
    t.wait('NY-1', 'shloop: nested Y-1')
    t.wait('NY-2', 'shloop: nested Y-2')
    t.wait_prompt('shloop: nested settled')

    # (e) a variable assigned INSIDE a spooled loop must still hold
    # its last value AFTER it -- the spooled file runs in the SAME
    # shell, not a child.
    t.type_human('FOR K IN M1 M2 ; DO SHV=$K ; DONE')
    t.enter()
    t.wait_prompt('shloop: variable-persist loop settled')
    t.type_human('ECHO Y$SHV')
    t.enter()
    t.wait('YM2', 'shloop: SHV kept its last value')
    t.wait_prompt('shloop: variable-persist settled')

    # (f) a glob word list -- the FORWORDMAX bug this feature
    # started from: any expanding word list used to hit "sh: for:
    # too many words" before an interactive loop could even run.
    # Relative (BIN/C*, not /bin/C*): CKSUM/CHMOD's full
    # absolute path overflows FORWORDLEN (16, a SEPARATE, pre-
    # existing per-word cap this feature does not touch) -- the
    # relative form keeps every match well under it.
    t.type_human('FOR F IN BIN/C* ; DO ECHO G$F ; DONE')
    t.enter()
    t.wait('GBIN/cat', 'shloop: glob matched cat')
    t.wait_prompt('shloop: glob settled')

    # (h) a DOUBLE-quoted word in the loop's own BODY, one-liner --
    # SPOOL_SPLIT must not treat the space inside "Q1 $I" as a word
    # boundary nor let it confuse the leading-word keyword check.
    t.type_human('FOR I IN AA BB ; DO ECHO "Q1 $I" ; DONE')
    t.enter()
    t.wait('Q1 AA', 'shloop: quoted body iteration 1')
    t.wait('Q1 BB', 'shloop: quoted body iteration 2')
    t.wait_prompt('shloop: quoted-body settled')

    # (i) a `;` INSIDE single quotes, on a multi-line body, must NOT
    # split the segment -- checked against the SCRIPT-FILE oracle
    # by hand (`. FILE` on a vi-authored file with this exact body
    # printed the identical "S;$I" twice): single quotes are
    # literal in this shell, `$I` included, so the loop's own
    # ECHO never expands it either way.
    #
    # `t.wait('S;$I', ...)` alone is a FALSE PASS here (found while
    # proving this case's own teeth): the typed body line's own
    # ECHOED INPUT ROW is `> ECHO 'S;$I'`, which already CONTAINS
    # the substring "S;$I" before the loop ever runs -- a broken
    # quote tracker that garbles the run still leaves that row on
    # the glass, and Term.wait would call that success. Require an
    # EXACT-MATCH output row (echo's own row is never bare "S;$I",
    # the quotes and "ECHO "/">" prefix make sure of that) TWICE,
    # one per iteration.
    for line in ('FOR I IN X Y', 'DO', "ECHO 'S;$I'", 'DONE'):
        t.type_human(line)
        t.enter()
    t.wait_prompt('shloop: quoted-semicolon settled')
    exact = sum(1 for r in t.screen() if r.strip() == 'S;$I')
    if exact < 2:
        raise AssertionError(
            f'shloop: expected "S;$I" as its OWN output row twice, '
            f'saw {exact}:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))

    # (j) a quote BEFORE the loop on its own line is refused loudly,
    # never spooled shifted -- diagnostic, prompt back, no SPL file.
    t.type_human('X="a b" ; FOR I IN CC ; DO ECHO $I ; DONE')
    t.enter()
    # a SHORT prefix of the diagnostic, not the whole 44-char
    # message -- Term.visible is per-row and the full string can
    # land straddling a 40-column wrap depending on prior noise.
    t.wait('sh: for/while: quoted',
           'shloop: quote-before-head refused')
    t.wait_prompt('shloop: refusal settled')

    # (g) leftover check -- every spool file above must be gone.
    t.type_human('LS')
    t.enter()
    t.wait_prompt('shloop: listing settled')
    if t.visible('SPL'):
        raise AssertionError(
            'shloop: a spool file is still on disk after several '
            'spooled loops:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))

    # (k) `exit` INSIDE a spooled loop must not leak its temp file.
    # A child `SH` first, so `exit` returns to THIS (outer) shell
    # rather than ending the whole session -- SH_EXIT (shtrap.s)
    # cleans up before the real EXIT either way.
    t.type_human('SH')
    t.enter()
    t.wait_prompt('shloop: child shell up')
    t.type_human('FOR I IN AA ; DO ECHO K$I ; EXIT ; DONE')
    t.enter()
    t.wait('KAA', 'shloop: child ran one iteration before exit')
    t.wait_prompt('shloop: back in the outer shell')
    t.type_human('LS')
    t.enter()
    t.wait_prompt('shloop: outer listing settled')
    if t.visible('SPL'):
        raise AssertionError(
            "shloop: exit inside a spooled loop leaked its temp "
            'file:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))

    # (l) `getopts` typed inside a console `while` loop (docs/SH-
    # FEATURES.md, 2026-09-15): the loop head is a builtin, not a
    # reserved word, so this proves SPOOL_ENTER's construct
    # detection and CHCK_BLTN_GOP compose correctly through the
    # SAME spooling path (a) already exercised. Explicit ARG...
    # (this shell has no `set --` to populate $1.. from the
    # console, so getopts's own ARG... form is what a console
    # session actually has): `-a -b x -c` clustered, then $OPTIND
    # read back once the loop is done proves it advanced past all
    # three options (5, one past the LAST of the four operands
    # "-a -b x -c" -- verified against this host's own getopts).
    #
    # MAXVARS=8, and this session already spent SIX slots on
    # `I`/`N`/`K`/`SHV`/`F`/`X` in the scenarios above -- getopts
    # needs three more (OPT/OPTIND/OPTARG), which overflows and
    # prints "sh: variable table full" instead of running at all
    # (found live running this exact case). `UNSET` every one of
    # them first -- harmless if a given name was never actually
    # set, `unset`'s own contract (24.1) -- to free real slots
    # this scenario does not otherwise need back.
    for name in ('I', 'N', 'K', 'SHV', 'F', 'X'):
        t.type_human('UNSET ' + name)
        t.enter()
        t.wait_prompt('shloop: getopts prep unset ' + name)
    t.type_human('WHILE GETOPTS ab:c OPT -a -b x -c ; '
                  'DO ECHO L$OPT:$OPTARG ; DONE')
    t.enter()
    t.wait('La:', 'shloop: getopts a (no arg)')
    t.wait('Lb:x', 'shloop: getopts b (required arg)')
    t.wait('Lc:', 'shloop: getopts c (no arg)')
    t.wait_prompt('shloop: getopts while settled')
    t.type_human('ECHO L2:$OPTIND')
    t.enter()
    t.wait('L2:5', 'shloop: OPTIND advanced past all three options')
    t.wait_prompt('shloop: getopts scenario settled')
    t.type_human('LS')
    t.enter()
    t.wait_prompt('shloop: getopts listing settled')
    if t.visible('SPL'):
        raise AssertionError(
            'shloop: getopts inside a console while loop leaked '
            'its spool temp file:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))


def case_shquote_console(t):
    """Quote CONCATENATION and the `"..."` backslash table, typed AT
    THE CONSOLE one key at a time (2026-09-15, docs/SH-FEATURES.md
    sec 23) -- the person-like proof scripts/e2e_corpus.py's static
    ShCase rows cannot give by themselves (that harness never touches
    a real key, and its two backslash rows have to route around the
    host's own `echo` re-interpreting a real backslash -- see
    quotebs-3/4's own comment -- so this case sticks to the two forms
    that leave no backslash in the FINAL argument, where `ECHO` is
    unambiguous on both sides).

    `'it''s'` and `"a"'b'c` prove adjacent quoted/bare segments
    CONCATENATE into one word instead of the old `sh: mixed
    quoting`; `"a\\"b"` and `"\\$X"` prove POSIX 2.2.3's backslash
    table inside "..." -- `\\"` strips to a bare `"`, `\\$` strips to
    a bare `$` that does NOT then expand (X is left unset on
    purpose). A closing `FOR`/`IN` row proves a CONCATENATED word
    (`'a'x`) survives the console-loop spooler's own line (SPOOL_
    SPLIT, shtrap.s, a SEPARATE, simpler scanner from TOKENIZE) as
    ONE list item, not two.
    """
    t.run_cmd_echoed("ECHO 'it''s'", 'shquote: adjacent single quotes')
    t.wait('its', 'shquote: concatenated single-quoted segments')
    t.wait_prompt('shquote: adjacent-singles settled')

    t.run_cmd_echoed('ECHO "a"\'b\'c', 'shquote: double+single+bare')
    t.wait('abc', 'shquote: double/single/bare concatenation')
    t.wait_prompt('shquote: mixed-concat settled')

    t.run_cmd_echoed('ECHO "a\\"b"', 'shquote: escaped double quote')
    t.wait('a"b', 'shquote: \\" strips to a literal quote, no close')
    t.wait_prompt('shquote: escaped-quote settled')

    t.run_cmd_echoed('ECHO "\\$X"', 'shquote: escaped dollar')
    t.wait('$X', 'shquote: \\$ strips but does not then expand')
    t.wait_prompt('shquote: escaped-dollar settled')

    # A FOR loop's own word list: `'a'x` is a QUOTED segment glued
    # to a BARE one, no blank between them -- the concatenation
    # this pass adds -- so the list is TWO items ('a'x -> "ax", and
    # c), not three. `Q[...]` prefixed so neither output is confused
    # with this line's own echoed input row. FOUR separate typed
    # lines, not one -- the one-liner form is 40 chars (plus the
    # `$ ` prompt) and WRAPS on the 40-col backend, which
    # `type_and_expect_echo`'s single-ROW substring check cannot
    # see past (found live: FAIL, "did NOT echo", on the exact
    # shape case_shloop_console's own docstring warns about).
    t.wait_prompt('shquote: FOR-loop prompt ready')
    t.type_human("FOR I IN 'a'x c")
    t.enter()
    t.wait('> ', 'shquote: secondary prompt after FOR')
    t.type_human('DO')
    t.enter()
    t.wait('> ', 'shquote: secondary prompt after DO')
    t.type_human('ECHO "Q[$I]"')
    t.enter()
    t.wait('> ', 'shquote: secondary prompt after body')
    t.type_human('DONE')
    t.enter()
    t.wait('Q[ax]', 'shquote: concatenated word stayed ONE item')
    t.wait('Q[c]', 'shquote: second (bare) list item')
    t.wait_prompt('shquote: FOR-quoting settled')


def case_shbrace_console(t):
    """`{ list ; }` brace groups and `${V%pat}`/`${V#pat}` pattern
    stripping, typed AT THE CONSOLE one key at a time (2026-09-15,
    docs/SH-FEATURES.md sec 3/4) -- the person-like proof
    scripts/e2e_corpus.py's static ShCase rows cannot give (that
    harness never touches a real key), same shape as
    case_shloop_console for the earlier loop-spooling landing.

    (a) `{` / `ECHO CA` / `ECHO CB` / `}` typed across four lines:
    each continuation shows the `> ` secondary prompt (the SAME
    machinery IF/WHILE/FOR already use -- `{`/`}` push and pop a
    construct-stack frame with no condition of its own), and the
    group runs in the CURRENT shell (proved separately below via a
    variable surviving past its own `}`).
    (b) `{ X=1 ; }` on one line, then `ECHO $X` on the NEXT: X=1
    is visible AFTER the group closes -- a subshell `( X=1 )` could
    never do this.
    (c) `${V%pat}`/`${V##pat}` typed as ordinary one-line commands:
    no construct-stack or spooling machinery involved, just the
    variable-expansion path, but never yet typed as real keystrokes
    rather than fed through the static corpus.
    """
    # (a) multi-line brace group with the `> ` secondary prompt.
    t.wait_prompt('shbrace: prompt ready for multi-line group')
    t.type_human('{')
    t.enter()
    t.wait('> ', 'shbrace: secondary prompt after {')
    t.type_human('ECHO CA')
    t.enter()
    t.wait('> ', 'shbrace: secondary prompt after body line 1')
    t.type_human('ECHO CB')
    t.enter()
    t.wait('> ', 'shbrace: secondary prompt after body line 2')
    t.type_human('}')
    t.enter()
    t.wait('CA', 'shbrace: multi-line group iteration 1')
    t.wait('CB', 'shbrace: multi-line group iteration 2')
    t.wait_prompt('shbrace: multi-line group settled')

    # (b) current-shell semantics: X=1 set inside `{ }` survives.
    t.run_cmd_echoed('{ X=1 ; }', 'shbrace: one-line group sets X')
    t.wait_prompt('shbrace: prompt after one-line group')
    t.run_cmd_echoed('ECHO XV=$X', 'shbrace: read X back')
    t.wait('XV=1', 'shbrace: X=1 survived past the group')
    t.wait_prompt('shbrace: X-readback settled')

    # (c) `${V%pat}`/`${V##pat}`, real keystrokes.
    t.run_cmd_echoed('F=/bin/ECHO', 'shbrace: set F')
    t.wait_prompt('shbrace: prompt after set F')
    t.run_cmd_echoed('ECHO Q[${F##*/}]', 'shbrace: F##*/')
    t.wait('Q[ECHO]', 'shbrace: F##*/ strips the longest prefix')
    t.wait_prompt('shbrace: F##*/ settled')

    t.run_cmd_echoed('X=a.b.c', 'shbrace: set X')
    t.wait_prompt('shbrace: prompt after set X')
    t.run_cmd_echoed('ECHO Q[${X%.*}]', 'shbrace: X%.*')
    t.wait('Q[a.b]', 'shbrace: X%.* strips the shortest suffix')
    t.wait_prompt('shbrace: X%.* settled')


def case_shbuiltins_console(t):
    """The six POSIX builtins of 2026-09-16 -- `command`, `type`,
    `eval`, `exec`, `readonly`, `times` (docs/SH-FEATURES.md sec 29) --
    typed AT THE CONSOLE, same shape as the two cases above.

    THIS CASE EXISTS FOR `times` SPECIFICALLY, and the reason is a
    property of the OTHER harness rather than of this one.
    check-shlang's third image covers all six against a byte-exact
    file, but src/test/shlangtest.s never `put`s src/kernel/timer.s and
    never calls TIMER_PROBE, so K_TIMER_MODE is 0 there and `times`
    correctly prints its structural-zero path -- which means SB_DIV60
    and SB_HUND, the whole elapsed arithmetic, never execute in that
    gate at all (measured 2026-09-16 by changing the zero string and
    watching it appear). The PLAY image DOES probe (src/test/
    playtestb.s calls TIMER_PROBE), so this is the one place the live
    path runs, and the assertion below is the one that matters: after
    a person has sat at the console typing, the shell's own elapsed
    field is NOT zero.

    The other four rows are the ordinary person-like proof: a builtin
    that only ever ran from a script file is not proven to run from a
    keyboard (docs/E2E.md, and the ^Z dead-echo bug that started this
    harness).
    """
    t.run_cmd_echoed('TYPE ECHO', 'shbuiltins: type a builtin')
    t.wait('is a shell builtin', 'shbuiltins: type names the builtin')
    t.wait_prompt('shbuiltins: type settled')

    t.run_cmd_echoed('COMMAND -v ECHO', 'shbuiltins: command -v')
    t.wait_prompt('shbuiltins: command -v settled')

    t.run_cmd_echoed('EVAL ECHO Q[EVOK]', 'shbuiltins: eval')
    t.wait('Q[EVOK]', 'shbuiltins: eval re-parsed and ran the line')
    t.wait_prompt('shbuiltins: eval settled')

    # `readonly` binds the assignment path, not just its own builtin.
    t.run_cmd_echoed('RV=1', 'shbuiltins: set RV')
    t.wait_prompt('shbuiltins: RV set')
    t.run_cmd_echoed('READONLY RV', 'shbuiltins: mark RV read-only')
    t.wait_prompt('shbuiltins: RV marked')
    t.run_cmd_echoed('RV=2', 'shbuiltins: assignment must be refused')
    t.wait('read-only variable', 'shbuiltins: the refusal is LOUD')
    t.wait_prompt('shbuiltins: refusal settled')
    t.run_cmd_echoed('ECHO Q[$RV]', 'shbuiltins: read RV back')
    t.wait('Q[1]', 'shbuiltins: the refused assignment changed nothing')
    t.wait_prompt('shbuiltins: RV readback settled')

    # `times`, on a machine whose tick source is REAL.
    t.run_cmd_echoed('TIMES', 'shbuiltins: times')
    t.wait('0m0.00s', 'shbuiltins: times printed a formatted pair')
    t.wait_prompt('shbuiltins: times settled')
    pat = re.compile(r'(\d+)m(\d+)\.(\d\d)s (\d+m\d+\.\d\ds)')
    elapsed = None
    for row in t.screen():
        for m in pat.finditer(row):
            secs = int(m.group(1)) * 60 + int(m.group(2)) + \
                int(m.group(3)) / 100.0
            if secs > 0:
                elapsed = (m.group(0).split()[0], secs)
    if elapsed is None:
        raise E.Wedged(
            'shbuiltins: `times` never printed a NONZERO elapsed field. '
            'This machine probed a real tick source (playtestb.s calls '
            'TIMER_PROBE) and a person has been typing at it for '
            'seconds, so SB_T0CAP or the 32-bit subtraction behind it '
            'is not working; screen:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))
    # A PLAUSIBILITY BOUND, not decoration: SB_DIV60 is a 32-pass
    # shift-and-subtract and the ways it goes wrong are gross ones (a
    # short pass count, a quotient bit landing in the wrong place), all
    # of which still print SOMETHING that matches the format. This case
    # has been up for well under a minute of emulated time, so anything
    # past five minutes is arithmetic, not elapsed time.
    if elapsed[1] > 300:
        raise E.Wedged(
            f'shbuiltins: `times` reported {elapsed[0]} elapsed, but '
            f'this console session is seconds old -- SB_DIV60 is '
            f'producing a number, not the right one; screen:\n' +
            '\n'.join(r.rstrip() for r in t.screen() if r.strip()))
    print(f'    [shbuiltins] times elapsed field = {elapsed[0]}',
          flush=True)


def case_shloop_virtual_cwd(t):
    """`for`/`while` typed with the cwd on a KERNEL-OWNED directory
    (KFIX3 item 5, docs/GLOB-VROOT-NOTES.md sec 8.1). The console
    spools the whole loop to a temp file (case_shloop_console); the
    file used to be a bare name for the cwd, and `/`, `/dev` and
    `/mnt` refuse a create, so every loop typed there printed `sh:
    for/while: cannot open spool file` and ran nothing. The spool
    lives in /tmp now. One FOR and one WHILE at each of the three
    directories; the output words are V/W-PREFIXED so they cannot be
    confused with the typed line's own echo. The shell is put back
    in its home directory at the end (the later cases expect it).
    """
    for d, tag in (('/', 'V1'), ('/dev', 'V2'), ('/mnt', 'V3')):
        t.type_human('CD ' + d)
        t.enter()
        t.wait_prompt(f'shloop_vcwd: cd {d}')
        t.type_human(f'FOR I IN AA BB ; DO ECHO {tag}$I ; DONE')
        t.enter()
        t.wait(f'{tag}AA', f'shloop_vcwd: FOR at {d} iteration 1')
        t.wait(f'{tag}BB', f'shloop_vcwd: FOR at {d} iteration 2')
        t.wait_prompt(f'shloop_vcwd: FOR at {d} settled')
        t.type_human(f'N=0 ; WHILE TEST $N -lt 2 ; DO ECHO W{tag}$N ; '
                     f'N=$(EXPR $N + 1) ; DONE')
        t.enter()
        t.wait(f'W{tag}0', f'shloop_vcwd: WHILE at {d} iteration 0')
        t.wait(f'W{tag}1', f'shloop_vcwd: WHILE at {d} iteration 1')
        t.wait_prompt(f'shloop_vcwd: WHILE at {d} settled')
        blob = '\n'.join(r for r in t.screen() if r.strip())
        if 'cannot open spool file' in blob:
            raise AssertionError(
                f'shloop_vcwd: the spool file could not be made at {d}:\n'
                + blob)
    t.type_human('CD /mnt/MAUX')
    t.enter()
    t.wait_prompt('shloop_vcwd: back home')


CASES = [
    ('wedge_hunt', case_wedge_hunt),
    ('shell_echo', case_shell_echo),
    ('vi_insert', case_vi_insert),
    ('insert_erase', case_insert_erase),
    ('scroll', case_scroll),
    ('suspend_echo', case_suspend_echo),
    ('nesting_edit', case_nesting_edit),
    ('shellout', case_shellout),
    ('shloop_console', case_shloop_console),
    ('shloop_virtual_cwd', case_shloop_virtual_cwd),
    ('shquote_console', case_shquote_console),
    ('shbrace_console', case_shbrace_console),
    ('shbuiltins_console', case_shbuiltins_console),
]

BACKENDS = ['text40', 'text80', 'ut']


def run_backend(backend, seed=1234):
    print(f'\n===== backend {backend} =====', flush=True)
    ok_all = True
    for name, fn in CASES:
        ok, err = E.session(backend, fn, seed=seed)
        if ok:
            print(f'[e2e-term] {backend}/{name}: PASS', flush=True)
        else:
            ok_all = False
            print(f'[e2e-term] {backend}/{name}: FAIL -- {err}',
                  file=sys.stderr, flush=True)
    return ok_all


def main():
    # replay a keylog recorded by `make play-rec`:
    #   python3 e2e_vi_term.py replay <klog> [backend]
    if len(sys.argv) > 1 and sys.argv[1] == 'replay':
        klog = sys.argv[2]
        backend = sys.argv[3] if len(sys.argv) > 3 else 'ut'

        def run(t):
            n = t.replay(klog)
            print(f'[e2e-term] replayed {n} keys from {klog} on {backend}',
                  flush=True)
            t.dump('after replay')
        ok, err = E.session(backend, run)
        if err:
            print(f'[e2e-term] replay error: {err}', file=sys.stderr)
        return 0 if ok else 1
    which = sys.argv[1] if len(sys.argv) > 1 else 'text40'
    only = sys.argv[2] if len(sys.argv) > 2 else None
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1234
    backends = BACKENDS if which == 'all' else [which]
    if only:
        for b in backends:
            fn = dict(CASES)[only]
            ok, err = E.session(b, fn, seed=seed)
            print(f'[e2e-term] {b}/{only}: '
                  f'{"PASS" if ok else "FAIL -- " + str(err)}',
                  flush=True)
        return 0
    ok = all(run_backend(b, seed) for b in backends)
    if ok:
        print('[e2e-term] all cases PASS', flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
