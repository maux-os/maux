#!/usr/bin/env python3
"""T4 stage-1b, E5's oracle-3 package: ps + pwd + df -- no host reference
exists for any of these, ever (docs/E2E.md sec 7.1, CONTRACT.md sec 1's
`'INVARIANT'` row). Every case here is `oracle='INVARIANT'`; every case
cites an INVARIANTS entry stating the property AND why nothing external
computes it, per the TL's explicit requirement that the gate print those
reasons on every run.

Why no host reference, in one line per tool (the case each tool's own
source makes for itself, verified below rather than assumed):

  ps   src/kernel PCB array is annex memory, outside every process's own
       address space; SYS_PSTAT (ps.s's whole reason to exist, per its
       own header) is maux's ONLY window on it, narrowed to a fixed
       6-byte record. No host `ps` shares maux's design where pid==bank
       ==slot by construction (ps.s's header: "keeps slot index == pid";
       V6 didn't even have a ps SYSCALL, let alone this scheme).
  pwd  ProDOS keeps ONE GLOBAL prefix, not a per-process cwd (pwd.s's
       own "SEMANTIC NOTE"). Every host pwd(1) reports a PER-PROCESS
       cwd via getcwd(2). Structurally different mechanisms; nothing on
       the host computes "the ProDOS prefix after this chdir sequence".
  df   df reports the USED/FREE split of an emulated ProDOS volume
       (one GET_FILE_INFO on the volume directory: aux_type = total
       blocks, blocks_used = blocks for all files). Host `df` reports
       free space on the HOST filesystem holding the disk image, not
       the emulated volume; nothing on the host computes either number
       for it, so the only host-checkable fact is Total == the image's
       byte size / 512 (check-df pins Used/Available against a2til).

STREET-LIBRARY LOOP (HACKING.md rule 3): learning:01M0PBKZKZE55J4NE93TYNJCPC
(ProDOS's GET_FILE_INFO resolves a bare `.`/`..` on its own, so a probe
call is the WRONG way to gate `.`) directly shapes how pwd's relative-
access cases are built below: every pwd assertion is paired with a
RELATIVE cat, never a bare existence/type probe, exactly per that
learning's own stated conclusion and per CONTRACT.md sec 8's paraphrase
of it (and per the task brief's own "pwd alone is not enough").

CONTRACT EXTENSIONS THIS MODULE ASSUMES (see the final report for the
full discussion):

  (1) `case.expect_status` (default 0) is how a VOL/INVARIANT-oracle
      case states its expected exit code, since there is no host
      reference to supply one (see scripts/e2e_fs_meta.py's own note --
      same assumption, reused here for consistency).

  (2) `volume` exposes `.total_blocks` (a2til's own VolHeader field,
      already a public a2til API -- `Volume.total_blocks`) and, where
      possible, the underlying image file's path/size (best-effort,
      several attribute names tried -- see `_image_size` below) for
      df's total_blocks-vs-image-bytes invariant.

  (3) For 'ps-pid-matches-spawn': `src/test/e2etestb.s:17` captures
      SC_SPAWN's returned pid for `sh` at a FIXED address, `R_SH_PID
      equ $1201` in the parent process's bank -- the exact mechanism
      scripts/check_v1_system.py and scripts/check_chmod.py already
      peek (`sh_pid = peek_aux1(client, R_SH_PID)[0]`). Since
      CONTRACT.md sec 3.5 says this tranche reuses e2etest.s/
      e2etestb.s UNCHANGED, that peek is almost certainly available to
      `check_e2e_fs.py` already. This module assumes it reaches the
      comparator as `case.spawn_pid` (set by the harness after the
      run); if that assumption is wrong, `cmp_ps_spawn` DEGRADES to a
      weaker, still-real check (the shell appears exactly once, in
      state S) and says so in its detail message rather than silently
      passing a weaker thing.

Every fixture name is prefixed `M5` (matches scripts/e2e_fs_meta.py's
convention) to avoid colliding with another package's RO names.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_limits as L        # noqa: E402
import e2e_compare as C       # noqa: E402

NAME = 'invariants'   # ps + pwd + df, for the gate log

#: df now prints the POSIX -P report (docs/DU-DF.md): this header, then
#: one "/VOL total used avail pct% /VOL" row per volume, all on STDOUT.
#: It used to print a one-time "used/free unavailable" note to stderr
#: on every invocation (PRINTNOTE); that note is gone with the
#: capability gap it described, so a `2>&1` capture is now just the
#: report. Used/Available are NOT pinned here -- the case's own `> file`
#: redirection allocates a block on this volume before df stats it, so
#: they differ between cases that are otherwise identical; scripts/
#: check_df.py pins them exactly against a2til's bitmap count. What
#: this comparator pins is the part that never moves: the header, the
#: row's shape, total == the image's byte size / 512, used + avail ==
#: total, and Capacity == ceil(100*used/total).
DF_HEADER = ('Filesystem 512-blocks Used Available Capacity '
             'Mounted on')

# ----------------------------------------------------------------------
# Fixtures.  All read-only: none of ps/pwd/df mutates the volume.
# M5PWDA/M5PWDB give pwd two nesting levels for the "two routes agree"
# case; each carries a MARK file so every pwd assertion is paired with
# a RELATIVE READ, never a bare probe (learning:01M0PBKZKZE55J4NE93TYNJCPC).
# ----------------------------------------------------------------------
RO_DIRS = ['M5PWDA', 'M5PWDA/M5PWDB']

RO_FILES = {
    'M5PWDA/M5MARK1': ('text', b'mark one\n', {'file_type': 0x04}),
    'M5PWDA/M5PWDB/M5MARK2': ('text', b'mark two\n', {'file_type': 0x04}),
}

MUT_TREES = {}

ENTRIES = {}     # this module cites no DIVERGENCE entries -- oracle 3
                 # has no reference to diverge FROM by definition.
DEFECTS = {}

# ----------------------------------------------------------------------
# NO_OUTPUT_PINS -- cases whose SYMPTOM IS THE MISSING OUTPUT FILE.
#
# Deliberately NOT `case.defect`.  A defect pin is judged inside
# e2e_fs_common.judge(), against output; these cases have no output to
# judge, so pinning them there made the selftest's own pin contract lie
# (five cases "absorbed a wrong stdout" only because their comparator is
# narrow, and the sixth failed outright).  A mechanism that cannot state
# its contract honestly is the wrong mechanism.
#
# Same ratchet shape as every other table here, enforced in
# check_e2e_fs.py and e2e_fs_selftest.py: the file being ABSENT is the
# pin (green, named every run); the file APPEARING means the defect is
# fixed and the entry must be deleted (red, loud); an entry naming a
# case_id that does not exist is stale and fails.
# ----------------------------------------------------------------------
NO_OUTPUT_PINS = {
    case_id: (
        "src/bin/sh.s's CHCK_BLTN_CD tests NCMD==1 and the command word "
        "and nothing else -- it never looks at CMD_OUTFILE -- so "
        "`CD X > FILE` runs the builtin and FILE is never created at "
        "all. On a Unix shell a redirection applies to a builtin like "
        "any other command: the file appears, empty for a silent "
        "success, holding the diagnostic for a failure.\n\n"
        "This is the SAME machinery gap sh.s already documents for the "
        "`echo` builtin, which handles it the other way: `ECHO X > F` "
        "deliberately falls through to the external ECHO binary, with a "
        "comment explaining why a builtin must not open the redirect "
        "itself -- OPEN_REDIR_WR drives a SINGLE shared set of shell "
        "parmlists (SH_OPARM, SH_CRT_PARM, SH_DSTRY_PARM, SH_PATHBUF, "
        "SH_APND_FD) meant to be driven from BLD_FDCTS_STG at "
        "pipeline-build time, and calling them from a builtin leaves "
        "state the next BLD_FDCTS_STG reads. That was MEASURED: "
        "check-v1-system's very next line produced an EMPTY file. `cd` "
        "has no external binary to fall through to, so it drops the "
        "redirect instead.\n\n"
        "THE FIX is the follow-up sh.s's own comment names: give the "
        "builtins their own parmlists. For `cd` that means a dedicated "
        "UNLINK+CREATE for `>` (CREATE-if-missing for `>>`) and -- for "
        "inv.failed-cd, which is `> F 2>&1` -- a real fd to write the "
        "diagnostic into, not merely an empty file. Pinned rather than "
        "fixed here because it is an sh feature with its own gates."
    )
    for case_id in (
        'inv.df-anchor', 'inv.cd-relative-step', 'inv.route-a-cd',
        'inv.route-b-anchor', 'inv.route-b-cd', 'inv.failed-cd',
    )
}

#: No KNOWN_DEFECTS entries. ps.s/pwd.s/df.s were each read in full
#: against their own header contracts and matched exactly; the ONE
#: platform fact worth flagging is not a maux bug: df.s's own header
#: (confirmed by reading it) explains, correctly, that blocks used/free
#: are UNREACHABLE with this kernel's syscall surface (no unit_num from
#: a volume name) -- that is df.s documenting its own honest limit, not
#: a defect maux should fix and hasn't.

GLOBALS = set()

# ----------------------------------------------------------------------
# INVARIANTS -- (property, why_no_reference_exists), the exact shape
# docs/E2E.md sec 7.1 and the TL's message require verbatim in the gate
# log.
# ----------------------------------------------------------------------
INVARIANTS = {
    'df-total-matches-image-size': (
        "df's printed Total (the first number of its -P row) equals the "
        ".po image FILE'S OWN byte size divided by 512 -- an external "
        "fact (os.path.getsize) that neither maux nor a2til computed, "
        "only reported. (df.s takes it from GET_FILE_INFO's aux_type on "
        "the volume directory, which a2til's VolHeader reads from the "
        "same header field, so comparing maux's answer to a2til's OWN "
        "parse of that field would be nearly circular; the image's raw "
        "byte count is the harder, independent ground truth -- "
        "scripts/build_chmod_image.py's compute_expectations() uses "
        "the same technique.) Used and Available are pinned exactly by "
        "check-df against a2til's bitmap count; here they are held to "
        "used + avail == total and Capacity == ceil(100*used/total).",
        "ProDOS keeps no host-visible 'total blocks' concept outside "
        "the volume itself, and no host `df` command reports anything "
        "about an emulated ProDOS volume's block count -- host df "
        "reports free space on the HOST filesystem holding the .po "
        "file, an unrelated number. There is nothing to run "
        "differentially."),
    'df-argument-forms-agree': (
        "`df`, `df MAUX`, `df /mnt/MAUX`, and `df /mnt/MAUX/RO/<path>` all "
        "report the same volume (/mnt/MAUX) with the same Total and a "
        "well-formed row, each by a different code path: the no-operand "
        "listing of every ONLINE volume, a bare name that is a volume "
        "(MAKESLASH's synthesized leading '/'), an already-slashed "
        "absolute volume path, and a deep path truncated at the second "
        "slash (VOLTRUNC). Used/Available are not compared across the "
        "forms: each case's own output file moves them.",
        "This is a composition property of maux's OWN four argv-"
        "handling branches (DOCWD/MAKESLASH/VOLTRUNC/PROCESSARG); no "
        "host `df` accepts ProDOS volume-name syntax ('BASIC' bare, or "
        "'/mnt/MAUX/RO/X' truncating at the volume) at all, so there is no "
        "reference command whose argument-parsing this could be "
        "differenced against."),
    'pwd-trailing-slash': (
        "pwd's output always ends `/` immediately before the `$8D` line "
        "terminator, on every prefix pwd is ever asked to print -- "
        "GET_PREFIX's own contract (ProDOS 8 TRM), which pwd.s passes "
        "through unmodified.",
        "POSIX pwd(1) never emits a trailing slash except for the "
        "degenerate root '/' -- this is ProDOS's own SET_PREFIX/"
        "GET_PREFIX pathname convention (CONTRACT.md sec 2c cites the "
        "same fact for ls -l's date column), not a Unix behaviour any "
        "host pwd could stand in for."),
    'pwd-cd-relative-compose': (
        "After `cd DIR` (absolute or relative), a SUBSEQUENT relative "
        "file access resolves INSIDE DIR, matching what pwd's printed "
        "string claims -- proving cd changed name RESOLUTION, not "
        "merely a string pwd echoes back (docs/CD.md's own gate-"
        "coverage note names this exact discipline: 'not just what pwd "
        "echoes').",
        "maux's design gives ProDOS ONE GLOBAL prefix shared by every "
        "process (pwd.s's own 'SEMANTIC NOTE'), unlike POSIX chdir(2)'s "
        "per-process cwd. No host shell/process shares this mechanism, "
        "so a host cd+pwd+relative-read sequence would validate the "
        "HOST's chdir semantics, not maux's -- a structurally different "
        "thing, not a reference for this one."),
    'pwd-two-routes-agree': (
        "`cd A` then `cd B` (two sequential relative chdirs) reaches "
        "the SAME prefix state -- provable by both pwd's string AND a "
        "relative read -- as `cd A/B` (one two-level relative chdir) "
        "from the same starting point.",
        "This checks maux's OWN prefix-resolution code path against "
        "ITSELF composed two different ways (chained SET_PREFIX calls "
        "vs. one SET_PREFIX with a two-component relative argument); "
        "nothing external independently computes 'the same ProDOS "
        "prefix' to compare against -- docs/CD.md records that plain "
        "relative cd chaining 'already worked' via ProDOS's own MLI "
        "before this task touched anything, which is exactly the kind "
        "of already-correct-but-unwritten-down property e2e corpora "
        "exist to protect as a regression, per docs/E2E.md sec 6 "
        "stage 3's warm-respawn rationale."),
    'pwd-failed-cd-unchanged': (
        "`cd NOSUCH` fails (nonzero exit) and leaves BOTH pwd's printed "
        "string AND a relative file access UNCHANGED from immediately "
        "before the attempt -- no partial state (docs/CD.md Ruling 4: "
        "'a failed cd leaves the process's directory unchanged -- no "
        "partial state, no accidental resolution against a "
        "half-updated anything').",
        "Verifying atomicity/no-partial-state on a failed chdir is an "
        "internal implementation property of maux's kernel "
        "(PRC_SETPFX not touching ProDOS's real prefix until its own "
        "SET_PREFIX call is known to succeed); nothing observable from "
        "a host process could stand in for it, since the object under "
        "test is maux's OWN kernel state, visible only through pwd's "
        "output and a relative read -- which is exactly the invariant, "
        "not a separate oracle."),
    'ps-pid-is-slot': (
        "ps's printed PID column is STRICTLY ASCENDING from the first "
        "printed row to the last -- the observable fingerprint of "
        "ps.s's own documented design, 'slot index == pid by "
        "construction' (ps.s header), given that REPORT is called in "
        "increasing SLOT order and only for occupied slots.",
        "No host `ps` assigns pid==the index into its OWN process-"
        "table array; Unix pids come from a global monotonic counter "
        "unrelated to any exposed table slot. This is an internal-"
        "consistency fact about maux's OWN pid<->bank<->slot scheme "
        "(ps.s's header: 'a process here IS a bank'), checkable only "
        "from ps's own output, never against a host."),
    'ps-parent-chain-well-formed': (
        "Pid 1 (the harness/init process) is ALWAYS printed, and PPID 0 "
        "is its UNIQUE signature -- no other row may ever hold it. "
        "Every other PPID ps prints equals some OTHER, DIFFERENT live "
        "PID also printed in the same ps output (a live ancestor, never "
        "0, never itself, never a dangling reference). Tightened "
        "2026-08-23 (PM review round 2) from 'PPID is 0 or a live pid, "
        "checked per-row' -- that looser statement let a mutant that "
        "shifted every PID and PPID by the same amount (no row's OWN "
        "chain link broke) walk through undetected by cmp_ps_ascending, "
        "which never called cmp_ps_parents at all; the tighter property "
        "(pid 1 must be PRESENT, and PPID 0 belongs to it EXCLUSIVELY) "
        "is what actually catches a whole-table shift, and is why the "
        "check moved into _parse_ps -- shared by every ps comparator, "
        "not owned by one of them.",
        "Process ancestry under maux's pid==bank==slot scheme has no "
        "host analogue to differentially compare against; this is "
        "checked purely by cross-referencing ps's own table against "
        "itself. Confirmed against the kernel (src/kernel/sched.s's "
        "SCH_CREATE zeroes PCB_PARENT for every process it creates; "
        "src/kernel/process.s:650-654 and src/kernel/procfork.s:449-466 "
        "both immediately overwrite it with the real spawning pid for "
        "every SPAWNED/FORKED child -- pid 1 alone is created directly "
        "by src/test/e2etestb.s's boot code, with no such overwrite; "
        "since ORPHAN-1 (2026-10-22) PRC_ADOPT also rewrites PCB_PARENT, "
        "but only to 1, a live pid, so the ancestry stays well formed), "
        "not asserted from the ps.s header alone."),
    'ps-pid-matches-spawn': (
        "The pid ps prints for the shell equals the pid value the test "
        "harness's OWN SC_SPAWN call returned when it launched sh "
        "(src/test/e2etestb.s:17's R_SH_PID) -- two independent routes "
        "(SC_PSTAT's kernel-table read vs. SC_SPAWN's own return value) "
        "to the same fact.",
        "Both routes are internal to maux's kernel (the PCB array read "
        "by SC_PSTAT, and SC_SPAWN's return path); a host process "
        "cannot observe either, so nothing external could compute or "
        "check this cross-reference."),
}


# ----------------------------------------------------------------------
# COMPARATORS
# ----------------------------------------------------------------------
def _image_size(volume):
    for attr in ('path', 'image_path', 'source', '_source', 'filename',
                 'disk_path'):
        p = getattr(volume, attr, None)
        if isinstance(p, str) and os.path.exists(p):
            return os.path.getsize(p)
    return None


def cmp_cd_status(case, got, ref, volume, hostdir):
    """Every 'cd' case here is plumbing for the pwd assertion that
    follows it; its own contract is just success/failure shape, per
    docs/E2E.md sec 9.7 (diagnostic wording is not differential, and
    this tranche has no reference for cd's wording either)."""
    # E7 integration fix, 2026-08-23: Case.expect_status defaults
    # to None (not absent), so getattr(case, 'expect_status', 0)
    # NEVER fell back to 0 -- every cd success case (expect_status
    # left at its None default) was silently treated as a FAILURE
    # case here, expecting a non-empty diagnostic. `or 0` treats
    # both None and 0 as 0, which is what this comparator always
    # meant.
    want_status = case.expect_status or 0
    if want_status == 0:
        if got != b'':
            return False, f'cd should be silent on success; got {got!r}'
    else:
        if got == b'':
            return False, ('cd should have printed a diagnostic on '
                           'failure (cd: no such directory)')
        # E7 integration fix, 2026-08-23: docs/E2E.md sec 9.6's own
        # named lesson -- non-emptiness alone cannot tell a real
        # diagnostic from one whose trailing $8D got silently dropped.
        # Wording still deliberately not checked (this function's own
        # docstring).
        if not got.endswith(b'\n'):
            return False, (f'cd diagnostic does not end with a line '
                           f'terminator: {got[-16:]!r}')
    return True, ''


def cmp_pwd_slash(case, got, ref, volume, hostdir):
    """`case.expect_prefix` is derived from the cd target THIS SCRIPT
    itself typed a moment earlier -- an input-derived fact, not one
    generated by running maux (docs/E2E.md sec 4's rule is about not
    recording maux's OWN output as an expectation; the argument we
    handed cd is ours, not maux's)."""
    if not got.endswith(b'/\n'):
        return False, f'pwd output does not end in "/\\n": {got!r}'
    want = case.expect_prefix.encode('ascii') + b'\n'
    if got != want:
        return False, f'pwd printed {got!r}, expected {want!r}'
    return True, ''


def cmp_exact_text(case, got, ref, volume, hostdir):
    """A relative read's content, checked against the fixture bytes WE
    staged (RO_FILES above) -- the pairing learning:01M0PBKZKZE55J4NE93TYNJCPC's
    own conclusion demands: pwd's string is not enough, a relative
    access must actually resolve and read the right bytes."""
    if got != case.expect_text:
        return False, f'expected {case.expect_text!r}, got {got!r}'
    return True, ''


def cmp_df_line(case, got, ref, volume, hostdir):
    image_size = _image_size(volume)
    degraded = image_size is None
    if degraded:
        total = getattr(volume, 'total_blocks', None)
        if total is None:
            return False, ('cannot determine either the image byte size '
                           'or volume.total_blocks -- see module '
                           'docstring CONTRACT EXTENSION (2)')
    else:
        total = image_size // 512
    want_volpath = getattr(case, 'expect_volpath', '/mnt/MAUX')
    detail_tail = ''
    if degraded:
        detail_tail = (' [DEGRADED: image byte size unavailable; used '
                       'volume.total_blocks, which is weaker -- see '
                       'INVARIANTS["df-total-matches-image-size"]]')
    lines = got.decode('ascii', 'replace').split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    else:
        return False, f'df output not newline-terminated: {got!r}'
    if len(lines) != 2 or lines[0] != DF_HEADER:
        return False, (f'expected the -P header then one row, got '
                       f'{got!r}' + detail_tail)
    m = re.fullmatch(r'(/\S+) (\d+) (\d+) (\d+) (\d+)% (/\S+)', lines[1])
    if not m or m.group(1) != want_volpath or m.group(6) != want_volpath:
        return False, (f'row is not "{want_volpath} total used avail '
                       f'pct% {want_volpath}": {lines[1]!r}')
    tot, used, avail, pct = (int(m.group(i)) for i in (2, 3, 4, 5))
    if tot != total:
        return False, (f'total {tot} != the image\'s {total} blocks'
                       + detail_tail)
    if used + avail != tot or not 0 < used <= tot:
        return False, f'used {used} + avail {avail} != total {tot}'
    if pct != -(-used * 100 // tot):
        return False, (f'Capacity {pct}% != ceil(100*{used}/{tot}) = '
                       f'{-(-used * 100 // tot)}%')
    return True, ''


def _parse_ps(got):
    """E7 integration fix, 2026-08-23: `got.split('\\n')` followed by
    dropping every empty element cannot tell 'properly terminated' from
    'the trailing $8D was silently dropped' -- docs/E2E.md sec 9.6's own
    named lesson ("keeping 'lines' and 'was it terminated' apart"),
    reproduced here: the selftest's own mutation battery caught this
    directly (a 'truncate one byte' mutant parsed identically to the
    correct answer). A properly-terminated `got` ends with '\\n' and
    splitting it drops exactly one trailing empty element; anything
    else is a missing terminator, checked BEFORE the blank-line filter
    quietly absorbs the evidence.

    E8 addition, 2026-08-23: also requires EXACTLY ONE row in state 'R'.
    ps.s's own header is explicit about this being a real invariant, not
    an assumption about this corpus's shape: "Running and runnable share
    a letter deliberately. Exactly one process is RUNNING at any instant
    and by construction it is this one" -- i.e. at the moment SC_PSTAT
    is read, the calling process (ps itself) is the one 'R' row. This
    corpus never backgrounds a job (`grep -n "'&'" scripts/e2e_fs_*.py
    scripts/e2e_invariants.py` -- nothing), so no OTHER process is ever
    concurrently runnable-but-not-running when any of this module's `ps`
    cases fire; "exactly one R row" is therefore sound for every case
    this file adds, not merely the synthetic teeth fixture. This is a
    STRUCTURAL parse-level well-formedness check shared by every
    comparator that calls _parse_ps (cmp_ps_ascending/_parents/_spawn),
    not a property of any ONE of them -- it is what closed cids 92/93/94
    ('drop a line'): dropping the fixture's third row was exactly
    dropping its one 'R' row, and none of the three comparators'
    PID/PPID-only checks noticed on their own.

    FINDING 3 fix, 2026-08-23 (adversarial review): the BANK column
    (parts[2]) used to be parsed and stored -- every caller received it
    as `bank` -- and then never checked by ANY of the three comparators
    (cmp_ps_parents even names it in its own `for pid, state, bank,
    ppid in rows` and leaves it unused). Meanwhile INVARIANTS
    ['ps-pid-is-slot'] is printed every run claiming exactly this
    relationship, and check_e2e_fs.py cites it as "an internal-
    consistency fact about maux's OWN pid<->bank<->slot scheme (ps.s's
    header: 'a process here IS a bank')" -- a claim nothing was
    verifying. Reviewer demonstrated case 92 passes with BANK forced to
    '00' on every row, and also with every bank number incremented.

    Read the real relationship from the kernel rather than inventing
    one: src/kernel/process.s:588-589 (PRC_SPAWN) and src/kernel/
    procfork.s:411-412 (PRC_FORK) both do `sta PRC_CHLD_BANK` then `sta
    PRC_CHILD_PID` off the SAME accumulator value -- procfork.s's own
    comment names it outright, "pid == bank, spawn's own convention".
    ps.s's REPORT prints PID in DECIMAL (PRCOL) and BANK in HEX
    (PRHEX2) -- same underlying byte, two different bases -- so the
    check parses BANK as hex and compares the integers, not the text.
    This is the SAME shape as the "exactly one R row" check just above:
    shared by every comparator that calls _parse_ps, checked once,
    here, rather than duplicated three times (and, per the reviewer's
    demonstration, left out of all three).

    PM review round 2, 2026-08-23: the FIRST cut of the BANK check above
    still let case 92 (cmp_ps_ascending) pass a mutant with every PID
    AND every BANK incremented by 1 (`1,2,3 -> 2,3,4`, banks shifted the
    same way) -- a uniform shift satisfies pid==bank at every row, and
    the PID column is still ascending, so neither of cmp_ps_ascending's
    own checks nor the BANK check above notices. What DOES notice is
    parent-chain well-formedness (cmp_ps_parents, case 93) -- but only
    on THIS specific corpus's fixture, where the shift happens to strand
    row 2's PPID (1) outside the shifted live set {2,3,4}. That is a
    coincidence of a 3-row fixture, not a real fix: a shift that also
    included PPID 0 unchanged (or a fixture with a self-contained cycle
    not rooted at pid 1) would slip through the SAME check.

    The real, general property -- confirmed by reading the kernel rather
    than inferring it from one mutant -- is tighter than "PPID is 0 or a
    live pid": PPID 0 is not a free choice any row may carry, it is the
    unique signature of pid 1 specifically. src/test/e2etestb.s's own
    boot code (`lda #1 / ldx #1 / jsr SCH_CREATE`) creates pid 1 (bank 1)
    directly, and SCH_CREATE (src/kernel/sched.s) unconditionally zeroes
    PCB_PARENT for every process it creates -- but src/kernel/
    process.s:650-654 (PRC_SPAWN) and src/kernel/procfork.s:449-466
    (PRC_FORK) BOTH immediately overwrite PCB_PARENT with the real
    spawning pid right after SCH_CREATE returns, for every process
    except pid 1 (created directly by the test harness, no PRC_SPAWN/
    PRC_FORK call, so nothing ever overwrites its zeroed PCB_PARENT).
    Grepping src/kernel/*.s for every PCB_PARENT writer (process.s:650,
    procfork.s:449/462, the SCH_CREATE zero itself) turns up one more
    since ORPHAN-1: PRC_ADOPT reparents orphans, but only to pid 1 --
    PPID 0 is therefore still both
    NECESSARY (pid 1 always has it) and SUFFICIENT (nothing writes 0
    but the zeroing) to identify pid 1, and pid 1 -- the harness's own root process, alive
    for the whole run -- must always be present in a real ps output.
    Checked here, shared, rather than only in cmp_ps_parents (which is
    what let the shift walk past cmp_ps_ascending in the first place):
    pid 1 must be printed; PPID 0 may be held ONLY by pid 1; every OTHER
    row's PPID must be some DIFFERENT live pid (never 0, never itself).
    See INVARIANTS['ps-parent-chain-well-formed'], tightened to state
    this precisely rather than the looser "0 or a live pid" it said
    before this fix."""
    if not got.endswith(b'\n'):
        return None, f'output does not end with a line terminator: {got[-16:]!r}'
    lines = got.decode('ascii', errors='strict').split('\n')[:-1]
    if not lines or lines[0] != ' PID S BANK PPID COMMAND':
        return None, f'missing/garbled header: {lines[:1]!r}'
    rows = []
    cmds = {}
    for row in lines[1:]:
        parts = row.split(None, 4)
        if len(parts) != 5:
            return None, (f'row does not parse into 4 fields and a '
                          f'COMMAND (PS-ARGS): {row!r}')
        try:
            pid = int(parts[0])
            ppid = int(parts[3])
        except ValueError:
            return None, f'non-numeric PID/PPID in row {row!r}'
        try:
            bank = int(parts[2], 16)
        except ValueError:
            return None, f'non-hex BANK in row {row!r}'
        if bank != pid:
            return None, (f'PID {pid} has BANK ${parts[2]} (={bank}) -- '
                          f'maux\'s own pid==bank convention '
                          f'(src/kernel/procfork.s:412, "pid == bank, '
                          f'spawn\'s own convention") requires BANK to '
                          f'equal PID for every row: {row!r}')
        rows.append((pid, parts[1], parts[2], ppid))
        cmds[pid] = parts[4]
    running = [r for r in rows if r[1] == 'R']
    if len(running) != 1:
        return None, (f'expected exactly one RUNNING (R) row -- ps.s\'s '
                      f'own header: "Exactly one process is RUNNING at '
                      f'any instant and by construction it is this one" '
                      f'-- got {len(running)}: {rows}')
    # PS-ARGS: the COMMAND column. pid 1 (the harness) was made by the
    # kernel, not spawned: `[init]`. The RUNNING row is ps itself and
    # its argv[0] is what the case typed; its parent is the shell.
    for pid, cmd in cmds.items():
        if not all(0x20 <= ord(ch) < 0x7F for ch in cmd):
            return None, f'pid {pid}: COMMAND is not printable: {cmd!r}'
    if cmds.get(1) != '[init]':
        return None, f'pid 1 COMMAND is {cmds.get(1)!r}, want [init]'
    if cmds[running[0][0]].casefold() != 'ps':
        return None, (f'the RUNNING row is ps itself; its COMMAND is '
                      f'{cmds[running[0][0]]!r}')
    if cmds.get(running[0][3], '').casefold() != 'sh':
        return None, (f'ps\'s parent is the shell; its COMMAND is '
                      f'{cmds.get(running[0][3])!r}')
    live = {r[0] for r in rows}
    if 1 not in live:
        return None, (f'pid 1 (the harness/init process -- src/test/'
                      f'e2etestb.s creates it directly with PCB_PARENT '
                      f'left at SCH_CREATE\'s zeroed default, and it is '
                      f'alive for the whole run) is not present in this '
                      f'ps output at all: {rows}')
    for pid, state, bank, ppid in rows:
        if ppid == pid:
            return None, f'pid {pid} lists itself as its own PPID: {rows}'
        if ppid == 0:
            if pid != 1:
                return None, (f'pid {pid} has PPID 0, but PPID 0 is the '
                              f'unique signature of pid 1 (src/kernel/'
                              f'process.s:650-654 and procfork.s:449-466 '
                              f'both overwrite PCB_PARENT with the real '
                              f'spawning pid right after SCH_CREATE '
                              f'zeroes it -- nothing ever reparents a '
                              f'process to 0 except pid 1\'s own direct, '
                              f'un-spawned creation): {rows}')
        elif ppid not in live:
            return None, (f'pid {pid} has PPID {ppid}, which is neither '
                          f'0 nor among the live pids printed: '
                          f'{sorted(live)}')
    return rows, ''


def cmp_ps_ascending(case, got, ref, volume, hostdir):
    rows, err = _parse_ps(got)
    if rows is None:
        return False, err
    if len(rows) < 2:
        return False, (f'only {len(rows)} row(s) printed -- ascending '
                       f'order is not a meaningful check with fewer '
                       f'than 2 live processes (non-degeneracy: this '
                       f'harness always has at least the init/harness '
                       f'process and sh)')
    pids = [r[0] for r in rows]
    if pids != sorted(pids):
        return False, f'PID column is not ascending: {pids}'
    if len(set(pids)) != len(pids):
        return False, f'duplicate PID in {pids}'
    return True, ''


def cmp_ps_parents(case, got, ref, volume, hostdir):
    """PM review round 2, 2026-08-23: parent-chain well-formedness (PPID
    0-or-live, no self-parent) used to be checked ONLY here -- which is
    exactly what let case 92 (cmp_ps_ascending) pass the reviewer's
    'every number +1' mutant: that comparator never calls this one, so
    a PID/BANK shift that keeps the chain looking locally consistent
    (or, worse, one that keeps the WHOLE chain consistent by shifting
    every PPID along with every PID) sails through cmp_ps_ascending's
    own ascending/duplicate checks untouched. Moved into _parse_ps
    itself -- shared by cmp_ps_ascending/_parents/_spawn alike, the same
    shape as the 'exactly one R row' and pid==bank checks already
    living there -- and STRENGTHENED there (PPID 0 is now the unique
    signature of pid 1, and pid 1 must be present; see _parse_ps's own
    docstring for the kernel citations). This function now just trusts
    _parse_ps: if `rows` parsed at all, the chain is already known
    well-formed, so there is nothing left for this comparator to
    duplicate."""
    rows, err = _parse_ps(got)
    if rows is None:
        return False, err
    return True, ''


def cmp_ps_spawn(case, got, ref, volume, hostdir):
    rows, err = _parse_ps(got)
    if rows is None:
        return False, err
    probe = getattr(case, 'spawn_pid', None)
    if probe is None and ref is not None:
        probe = getattr(ref, 'sh_pid', None)
    if probe is not None:
        if probe not in {r[0] for r in rows}:
            return False, (f'harness-captured spawn pid {probe} '
                           f'(e2etestb.s R_SH_PID) does not appear in '
                           f'ps output at all: {rows}')
        return True, (f'confirmed: SC_SPAWN-returned pid {probe} matches '
                      f'a row SC_PSTAT reported')
    sleeping = [r for r in rows if r[1] == 'S']
    if len(sleeping) != 1:
        return False, (f'[DEGRADED: no harness-captured SC_SPAWN pid was '
                       f'available -- see CONTRACT EXTENSION (3)] '
                       f'expected exactly one sleeping (S) process (the '
                       f'shell, blocked in wait()), found {sleeping} of '
                       f'{rows}')
    return True, ('[DEGRADED: matched by state heuristic only -- no '
                  'harness-captured SC_SPAWN pid was available]')


COMPARATORS = {
    'cd_status': cmp_cd_status,
    'pwd_slash': cmp_pwd_slash,
    'exact_text': cmp_exact_text,
    'df_line': cmp_df_line,
    'ps_ascending': cmp_ps_ascending,
    'ps_parents': cmp_ps_parents,
    'ps_spawn': cmp_ps_spawn,
}


# ----------------------------------------------------------------------
# synth() -- never used by the real gate; only by the selftest, to
# have something correct to corrupt (CONTRACT.md sec 7).
# ----------------------------------------------------------------------
def synth(case, ref_out, ref_err, ref_extra, volume, hostdir):
    k = case.compare
    if k == 'cd_status':
        return b'' if (case.expect_status or 0) == 0 else \
            C.encode_maux_text(b'cd: no such directory\n')
    if k == 'pwd_slash':
        return C.encode_maux_text(case.expect_prefix.encode('ascii') + b'\n')
    if k == 'exact_text':
        return C.encode_maux_text(case.expect_text)
    if k == 'df_line':
        image_size = _image_size(volume)
        total = (image_size // 512) if image_size is not None \
            else volume.total_blocks
        want_volpath = getattr(case, 'expect_volpath', '/mnt/MAUX')
        used = 123                       # any 0 < used <= total
        pct = -(-used * 100 // total)
        return C.encode_maux_text(
            (DF_HEADER + '\n' + f'{want_volpath} {total} {used} '
             f'{total - used} {pct}% {want_volpath}\n').encode('ascii'))
    if k in ('ps_ascending', 'ps_parents', 'ps_spawn'):
        # A plausible, well-formed 4-process table: init(0), sh(1, S),
        # ps itself (2, R). Good enough to exercise all three
        # comparators' ACCEPT path; the selftest's mutants corrupt it.
        rows = [(1, 'S', '01', 0, '[init]'), (2, 'S', '02', 1, 'SH'),
                (3, 'R', '03', 2, 'ps')]
        lines = [' PID S BANK PPID COMMAND']
        for pid, state, bank, ppid, cmd in rows:
            lines.append(f'{pid:>4} {state}   {bank} {ppid:>4} {cmd}')
        text = ''.join(l + '\n' for l in lines)
        return C.encode_maux_text(text.encode('ascii'))
    raise AssertionError(f'no synthesiser for compare={k!r}')


# ----------------------------------------------------------------------
# Cases
# ----------------------------------------------------------------------
def cases(add):
    RO = '/mnt/MAUX/RO'

    # ==== df: bare / bare-volname / absolute / deep-path forms =====
    c = add('cd', case_id='inv.df-anchor',
            sh_words=['CD', '/mnt/MAUX'], oracle='INVARIANT',
            invariant='df-argument-forms-agree', compare='cd_status',
            note='anchor: known prefix before the bare-df form')

    # `.` and not bare: with no operand df lists every ONLINE volume
    # through SYS_DEVLIST, whose real body is KSEG-resident in the full
    # kernel; this rig's MAUXE2E.SYSTEM carries only the ERR_NOSYS stub,
    # so a bare df prints just the header here (check-df covers the
    # listing on the real kernel).
    c = add('df', case_id='inv.df-current-prefix',
            argv=['.'], oracle='INVARIANT',
            invariant='df-total-matches-image-size', compare='df_line',
            note='df . -- volume of the current prefix')
    c.expect_volpath = '/mnt/MAUX'

    c = add('df', case_id='inv.df-bare-volname',
            argv=['MAUX'], oracle='INVARIANT',
            invariant='df-argument-forms-agree', compare='df_line',
            note='bare volume name -> MAKESLASH synthesizes the '
                 'leading slash')
    c.expect_volpath = '/mnt/MAUX'

    c = add('df', case_id='inv.df-absolute-volpath',
            argv=['/mnt/MAUX'], oracle='INVARIANT',
            invariant='df-argument-forms-agree', compare='df_line',
            note='already-absolute volume path')
    c.expect_volpath = '/mnt/MAUX'

    c = add('df', case_id='inv.df-deep-path',
            argv=[f'{RO}/M5PWDA/M5PWDB/M5MARK2'], oracle='INVARIANT',
            invariant='df-argument-forms-agree', compare='df_line',
            note='deep path -- VOLTRUNC truncates at the SECOND slash '
                 'to /mnt/MAUX regardless of depth')
    c.expect_volpath = '/mnt/MAUX'

    # ==== pwd: baseline, cd composes, two routes agree, failed cd ==
    c = add('pwd', case_id='inv.pwd-anchor',
            argv=[], oracle='INVARIANT',
            invariant='pwd-trailing-slash', compare='pwd_slash',
            note='baseline pwd at the anchor prefix')
    c.expect_prefix = '/mnt/MAUX/'

    c = add('cd', case_id='inv.cd-relative-step',
            sh_words=['CD', f'{RO}/M5PWDA'], oracle='INVARIANT',
            invariant='pwd-cd-relative-compose', compare='cd_status')

    c = add('pwd', case_id='inv.pwd-after-relative-cd',
            argv=[], oracle='INVARIANT',
            invariant='pwd-cd-relative-compose', compare='pwd_slash')
    c.expect_prefix = '/mnt/MAUX/RO/M5PWDA/'

    c = add('cat', case_id='inv.cat-after-relative-cd',
            sh_words=['/bin/CAT', 'M5MARK1'], oracle='INVARIANT',
            invariant='pwd-cd-relative-compose', compare='exact_text',
            note='RELATIVE read -- the pairing '
                 'learning:01M0PBKZKZE55J4NE93TYNJCPC demands: pwd\'s '
                 'string alone would pass even if resolution never '
                 'moved')
    c.expect_text = b'mark one\n'

    # -- route A: two chained relative cds --
    c = add('cd', case_id='inv.route-a-cd',
            sh_words=['CD', 'M5PWDB'], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='cd_status',
            note='route A step 1: relative cd from M5PWDA')

    c = add('pwd', case_id='inv.route-a-pwd',
            argv=[], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='pwd_slash')
    c.expect_prefix = '/mnt/MAUX/RO/M5PWDA/M5PWDB/'

    c = add('cat', case_id='inv.route-a-cat',
            sh_words=['/bin/CAT', 'M5MARK2'], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='exact_text')
    c.expect_text = b'mark two\n'

    # -- route B: one two-level absolute cd, from a reset anchor --
    c = add('cd', case_id='inv.route-b-anchor',
            sh_words=['CD', '/mnt/MAUX'], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='cd_status',
            note='route B step 0: reset to the anchor')

    c = add('cd', case_id='inv.route-b-cd',
            sh_words=['CD', f'{RO}/M5PWDA/M5PWDB'],
            oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='cd_status',
            note='route B step 1: ONE two-level relative-to-/mnt/MAUX cd')

    c = add('pwd', case_id='inv.route-b-pwd',
            argv=[], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='pwd_slash',
            note='must agree with route A\'s pwd above, byte for byte')
    c.expect_prefix = '/mnt/MAUX/RO/M5PWDA/M5PWDB/'

    c = add('cat', case_id='inv.route-b-cat',
            sh_words=['/bin/CAT', 'M5MARK2'], oracle='INVARIANT',
            invariant='pwd-two-routes-agree', compare='exact_text',
            note='must agree with route A\'s relative read above')
    c.expect_text = b'mark two\n'

    # -- failed cd leaves state (string AND relative access) unchanged --
    c = add('cd', case_id='inv.failed-cd',
            sh_words=['CD', 'NOSUCH'], oracle='INVARIANT',
            invariant='pwd-failed-cd-unchanged', compare='cd_status',
            note='must fail -- NOSUCH does not exist under '
                 '/mnt/MAUX/RO/M5PWDA/M5PWDB')
    c.expect_status = 1

    c = add('pwd', case_id='inv.pwd-after-failed-cd',
            argv=[], oracle='INVARIANT',
            invariant='pwd-failed-cd-unchanged', compare='pwd_slash',
            note='must be BYTE-IDENTICAL to the pre-failure pwd above')
    c.expect_prefix = '/mnt/MAUX/RO/M5PWDA/M5PWDB/'

    c = add('cat', case_id='inv.cat-after-failed-cd',
            sh_words=['/bin/CAT', 'M5MARK2'], oracle='INVARIANT',
            invariant='pwd-failed-cd-unchanged', compare='exact_text',
            note='relative access must STILL resolve to the '
                 'pre-failure directory, not merely the printed string',
            cwd='restore')
    c.expect_text = b'mark two\n'

    # ==== ps: three properties off one shared output shape =========
    c = add('ps', case_id='inv.ps-ascending',
            argv=[], oracle='INVARIANT',
            invariant='ps-pid-is-slot', compare='ps_ascending',
            note='PID column strictly ascending -- the observable '
                 'fingerprint of pid==slot by construction')

    c = add('ps', case_id='inv.ps-parents',
            argv=[], oracle='INVARIANT',
            invariant='ps-parent-chain-well-formed', compare='ps_parents',
            note='every PPID is 0 or a live PID in the same table')

    c = add('ps', case_id='inv.ps-spawn',
            argv=[], oracle='INVARIANT',
            invariant='ps-pid-matches-spawn', compare='ps_spawn',
            note='sh\'s printed pid == SC_SPAWN\'s own return value '
                 '(e2etestb.s R_SH_PID) -- two independent kernel '
                 'routes to one fact')
