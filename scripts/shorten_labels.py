#!/usr/bin/env python3
"""shorten_labels.py -- bring symbol names under real Merlin's 13-character
label limit (learning:01M050C6KW01MPJ2TQTPMTZXN6) without changing an emitted byte.

WHY THIS IS NOT OPTIONAL, AND NOT A BUILD-TIME MANGLE

Merlin-8 rejects any label field longer than 13 characters outright -- "Bad
label in line: N", not a truncation, so the symbol simply never gets defined
and every reference to it then fails too. A leading ':' on a local label
counts toward the 13, so locals get 12.

The tempting alternative is to keep long names in the tree and mangle them
into Merlin-safe names as a build step. That is wrong for THIS project: task
#8 is real Merlin, running under maux, assembling this tree. A tree that
needs a host-side preprocessor to be legal cannot be self-hosted -- you could
not edit and reassemble a module on the machine. The names have to be legal
in the source of record.

STRATEGY

Names here are structured SUBSYSTEM_MIDDLE_ROLE, and BOTH ends carry the
meaning: the first word is what a reader navigates by, and the last is what
distinguishes members of a family -- FAKEPROC_SRC_END from FAKEPROC_SRC_LEN,
ANNEX_STRUCTS_A from _B from _C. So the squeeze goes into the MIDDLE first,
and the ends give only when it is not enough.

A first version shrank from the right and produced exactly the predictable
disaster: FAKEPROC_SRC_END -> FAKEPROC_SRC_ and FAKEPROC_SRC_LEN ->
FAKEPROC_SRC2, i.e. it deleted the distinguishing suffix and then papered
over the collision it had just caused with a digit. Numeric disambiguation is
therefore a REPORTED FAILURE here, not a fallback -- if two members of a
family collide, the family needs a human name, not a counter.

SAFETY

Renaming cannot change object code. So the proof this ran correctly is that
every build artifact is byte-identical afterwards; `make check-bytes` is the
gate, exactly as it was for the comment rewrap.

Usage:  python3 scripts/shorten_labels.py [--apply] [--map]
"""
import os
import re
import sys
import collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIMIT = 13
SRC_EXT = ('.s', '.equ')
SKIP = ('/.git', '/build', '/vendor', '/docs')

# Word-level abbreviations. Ordered application: longest key first, so
# ADVANCE is not eaten by ADV. Chosen to stay pronounceable -- these names
# are read far more often than they are typed.
ABBREV = {
    'ADVANCE': 'ADV', 'ALLOCATE': 'ALLOC', 'APPEND': 'APP', 'ARGUMENT': 'ARG',
    'AVAILABLE': 'AVAIL', 'BACKSPACE': 'BS', 'BOUNDS': 'BND', 'BUFFER': 'BUF',
    'CHILD': 'CHLD', 'COLUMN': 'COL', 'COMMAND': 'CMD',
    'COMPARE': 'CMP', 'CONTEXT': 'CTX', 'CONTINUE': 'CONT', 'COPY': 'CPY',
    'COUNT': 'CNT', 'CURRENT': 'CUR', 'DEFAULT': 'DFLT', 'DESCRIPTOR': 'DESC',
    'DESTINATION': 'DST', 'DISPATCH': 'DISP', 'ENTRY': 'ENT', 'ERROR': 'ERR',
    'ESCAPE': 'ESC', 'EXECUTE': 'EXEC', 'FIELD': 'FLD', 'HANDLE': 'HND',
    'INDEX': 'IDX', 'INITIAL': 'INIT', 'INITIALISE': 'INIT',
    'INITIALIZE': 'INIT', 'LENGTH': 'LEN', 'MESSAGE': 'MSG', 'NUMBER': 'NUM',
    'OFFSET': 'OFS', 'PARAMETER': 'PARM', 'PARENT': 'PAR', 'POINTER': 'PTR',
    'POINTERS': 'PTRS', 'POSITION': 'POS', 'PROCESS': 'PROC',
    'RECEIVE': 'RECV', 'REGISTER': 'REG', 'RELEASE': 'REL', 'REQUEST': 'REQ',
    'RESERVED': 'RSVD', 'RESTORE': 'RSTR', 'RETURN': 'RET', 'SAVED': 'SAV',
    'SCHEDULE': 'SCHED', 'SEGMENT': 'SEG', 'SELECT': 'SEL', 'SOURCE': 'SRC',
    'STATUS': 'STAT', 'STRING': 'STR', 'SWITCH': 'SW', 'TABLE': 'TBL',
    'TEMPORARY': 'TMP', 'VALUE': 'VAL', 'WRITE': 'WR', 'READ': 'RD',
    'SETUP': 'SETUP', 'STAGE': 'STG', 'SLOT': 'SLT',
    # domain nouns, so the subsystem word can give ground legibly
    'FAKEPROC': 'FKPRC', 'BUILTIN': 'BLTN', 'SYSCALL': 'SYSC',
    'PRODOS': 'P8', 'STRUCTS': 'STRCT', 'FDACTIONS': 'FDACTS',
    'SUBEXPAND': 'SBXPND', 'SUBCOPY': 'SBCPY', 'VERBATIM': 'VERB',
    'FILENAME': 'FNAME', 'READBACK': 'RDBACK', 'SCHEDTEST': 'ST',
    'HANDLER': 'HNDLR', 'PRINTABLE': 'PRNTBL', 'DISCONNECT': 'DISCON',
    'RECONNECT': 'RECON', 'INTERCEPT': 'INTCPT', 'VISIBLE': 'VIS',
    'PENDING': 'PEND', 'ACQUIRE': 'ACQ', 'SERVICE': 'SVC',
    'UNLOCKED': 'UNLKD', 'FORBIDDEN': 'FORBID', 'NOTWIRED': 'NOWIRE',
    'UNWIRED': 'UNWIRE', 'AUXTYPE': 'AUXTYP', 'EXITSTATUS': 'EXITSTAT',
    'POSTGETTIME': 'POSTGT', 'PREGETTIME': 'PREGT', 'SLOTROM': 'SLTROM',
    'READERS': 'RDRS', 'CURBANK': 'CURBNK', 'MAXLEN': 'MAXLN',
    'IMAGE': 'IMG', 'TARGET': 'TGT', 'NORMAL': 'NORM', 'FRAME': 'FRM',
    'PRINTABLE2': 'PRNTBL',
}

# Role words: the last component of a family name. Never abbreviated and
# never truncated -- these are exactly what tells family members apart.
ROLE = {'END', 'LEN', 'SRC', 'DST', 'LO', 'HI', 'PTR', 'BUF', 'MSG', 'TXT',
        'IDX', 'CNT', 'MAX', 'MIN', 'ERR', 'OFS', 'A', 'B', 'C', 'D',
        'REQ', 'REF', 'VAL', 'STAT', 'FLD', 'TBL', 'NUM'}

# Names where the mechanical rule gives something unreadable. Hand-chosen.
OVERRIDE = {
    'SCHEDTEST_SELECT_CURBANK': 'ST_SELCURBNK',
    'ZP_RESERVED_PRODOS_LO': 'ZP_RSVDP8_LO',
    'ZP_RESERVED_PRODOS_HI': 'ZP_RSVDP8_HI',
    ':closed_echo_write': ':clsd_echo_wr',
    ':opened_echo_read': ':opnd_echo_rd',
    ':closed_echo_read': ':clsd_echo_rd',
    ':opened_readback': ':opnd_rdback',
    ':closed_readback': ':clsd_rdback',
    ':nomorematches': ':nomorematch',
    ':maybedispatch': ':maybedisp',
    ':opened_script': ':opnd_script',
    # Four-short-word names: no mechanical rule wins these without
    # destroying a word that carries meaning, so they are named by hand.
    'PROC_MLI_OPEN_USER_CALL': 'PMLI_OPEN_USR',
    'PROC_COPY_ARG_STRING': 'PCPY_ARG_STR',
    'PROC_COPY_SPAWN_PATH': 'PCPY_SPWN_PTH',
    'PROC_CLOSE_RAW_REF_A': 'PCLS_RAWREF_A',
    'PRINT_CMD_NOT_FOUND': 'PR_CMDNOTFND',
    'PROC_PCB_WRITE_BYTE': 'PPCB_WR_BYTE',
    'TTY_CSI_ERASE_LINE': 'TTY_CSI_ERSLN',
    'PROC_COPY_MLI_PATH': 'PCPY_MLI_PATH',
    'PROC_CLOSE_ALL_FDS': 'PCLS_ALL_FDS',
    'TIMER_ARM_NOP_HOOK': 'TMR_ARM_NOPHK',
    'PROC_CLOSE_ONE_FD': 'PCLS_ONE_FD',
    'EDSCR1_TEXT_LEN': 'EDSCR1_TXTLEN',
    'EDSCR2_TEXT_LEN': 'EDSCR2_TXTLEN',
    'PROC_GET_FD_OBJ': 'PRC_GET_FDOBJ',
    'PROC_SET_FD_OBJ': 'PRC_SET_FDOBJ',
    'PROC_CUR_FD_OBJ': 'PRC_CUR_FDOBJ',
    'TTY_VT_SEQ_LEN': 'TTY_VTSEQ_LEN',
}


# Family prefixes. Applied BEFORE word abbreviation, longest match first.
#
# This is the step that actually solves the problem. Squeezing word by word
# fails on four-word names because the subsystem prefix has already eaten
# a third of the budget: PROC_MLI_OPEN_PARMS has 9 characters of prefix
# before it says anything. Naming the FAMILY once -- PROC_MLI_ is "the
# process module's MLI parameter blocks", so PMLI_ -- buys back the room and
# reads better than PRC_MLI_OPN_PARMS ever would.
PREFIX = [
    ('K_BUILTIN_', 'K_BLTN_'),
    ('K_DISPATCH_', 'K_DISP_'),
    ('PROC_MLI_', 'PMLI_'),
    ('PROC_PIPE_', 'PPIPE_'),
    ('PROC_COPYOUT_', 'PCPO_'),
    ('PROC_COPYIN_', 'PCPI_'),
    ('PROC_ALLOC_OBJ_', 'PALOBJ_'),
    ('PROC_STAGE_', 'PSTG_'),
    ('PROC_READ_PARENT_', 'PRDPAR_'),
    ('PROC_WRITE_PARENT_', 'PWRPAR_'),
    ('PROC_READ_FDA_', 'PRDFDA_'),
    ('PROC_ADVANCE_', 'PADV_'),
    ('PROC_', 'PRC_'),
    ('SPAWN_IMG_', 'SIMG_'),
    ('SCHED_TICK_', 'STICK_'),
    ('SCHED_CALL_', 'SCALL_'),
    ('SCHED_', 'SCH_'),
    ('KERNEL_', 'KRN_'),
    ('COPYOUT_LC_', 'CPOLC_'),
    ('COPYIN_LC_', 'CPILC_'),
    ('FAKEPROC_', 'FKP_'),
    ('SCHEDTEST_', 'ST_'),
    ('TESTCALL_', 'TCALL_'),
    ('PRINT_', 'PR_'),
]


def _prefix(name):
    for long, short in sorted(PREFIX, key=lambda p: -len(p[0])):
        if name.startswith(long) and len(name) > len(long):
            return short + name[len(long):]
    return name


def _squeeze(parts, idxs, table=True):
    """Try the dictionary (or vowel-drop) on the given positions, in order,
    stopping as soon as the whole name fits."""
    for i in idxs:
        if len('_'.join(parts)) <= LIMIT:
            return
        w = parts[i]
        if table:
            parts[i] = ABBREV.get(w, w)
        elif len(w) > 3:
            parts[i] = w[0] + re.sub(r'[AEIOU]', '', w[1:])


def abbreviate(name):
    if name in OVERRIDE:
        return OVERRIDE[name]
    parts = _prefix(name).split('_')
    if len(parts) == 1:
        return ABBREV.get(name, name)
    last = len(parts) - 1
    middle = list(range(1, last))
    protected = parts[last] in ROLE

    _squeeze(parts, middle)                       # 1. dictionary, middle
    if not protected:
        _squeeze(parts, [last])                   # 2. dictionary, role word
    _squeeze(parts, [0])                          # 3. dictionary, subsystem
    _squeeze(parts, middle, table=False)          # 4. vowel-drop, middle
    _squeeze(parts, [0], table=False)             # 5. vowel-drop, subsystem

    if not protected:                             # 5b. vowel-drop the tail
        _squeeze(parts, [last], table=False)

    # 6. Last resort: truncate middle words, never below 3 chars, never the
    #    role word. If this still is not enough the name needs a human.
    for i in middle:
        if len('_'.join(parts)) <= LIMIT:
            break
        over = len('_'.join(parts)) - LIMIT
        parts[i] = parts[i][:max(3, len(parts[i]) - over)]
    if len('_'.join(parts)) > LIMIT and not protected:
        over = len('_'.join(parts)) - LIMIT
        parts[last] = parts[last][:max(4, len(parts[last]) - over)]
    return '_'.join(parts)


def collect():
    """Every symbol DEFINED in the tree, with the file it came from."""
    defs, local_defs = {}, {}
    for root, _, files in os.walk(ROOT):
        if any(p in root for p in SKIP):
            continue
        for f in sorted(files):
            if not f.endswith(SRC_EXT):
                continue
            p = os.path.join(root, f)
            for line in open(p, errors='replace'):
                m = re.match(r'^([A-Za-z][A-Za-z0-9_.]*)', line)
                if m:
                    defs.setdefault(m.group(1), p)
                    continue
                m = re.match(r'^(:[A-Za-z0-9_.]+)', line)
                if m:
                    local_defs.setdefault(m.group(1), p)
    return defs, local_defs


def build_map(defs, local_defs):
    taken = {d for d in defs if len(d) <= LIMIT}
    mapping, failed = {}, []
    for name in sorted((d for d in defs if len(d) > LIMIT), key=len,
                       reverse=True):
        cand = abbreviate(name)
        # No numeric disambiguation: a collision means two family members
        # would become indistinguishable, which is the bug this tool exists
        # to avoid. Report it and let a human name the family.
        if len(cand) > LIMIT or cand in taken or cand.endswith('_'):
            failed.append((name, cand))
            continue
        taken.add(cand)
        mapping[name] = cand
    # FAMILY CLOSURE. If any member of a prefix family had to be renamed,
    # rename EVERY member -- including ones already inside the limit.
    #
    # Skipping the legal ones splits the family: K_DISPATCH_COUNT (16) gets
    # shortened to K_DISP_COUNT while K_DISPATCH_LO (13) does not, and the
    # references no longer agree with the definitions. merlin32 does not stop
    # for that -- it resolved the now-undefined symbols to zero and emitted a
    # working-looking but wrong image. Only the byte-compare caught it. So
    # closure is a correctness requirement here, not tidiness.
    for long, short in PREFIX:
        fam = [d for d in defs if d.startswith(long) and len(d) > len(long)]
        if not any(f in mapping for f in fam):
            continue
        for f in fam:
            if f in mapping:
                continue
            cand = abbreviate(f)
            if len(cand) > LIMIT or (cand in taken and cand != f):
                failed.append((f, cand))
                continue
            taken.add(cand)
            mapping[f] = cand
    # Locals: budget is 12 plus the ':'. These are lowercase, in-routine, and
    # only 8 of them, so vowel-dropping the middle is fine.
    ltaken = {d for d in local_defs if len(d) <= LIMIT}
    for name in sorted((d for d in local_defs if len(d) > LIMIT), key=len,
                       reverse=True):
        if name in OVERRIDE:
            cand = OVERRIDE[name]
            if len(cand) <= LIMIT and cand not in ltaken:
                ltaken.add(cand); mapping[name] = cand
                continue
        words = name[1:].split('_')
        for i in range(len(words) - 1):
            if len(':' + '_'.join(words)) <= LIMIT:
                break
            if len(words[i]) > 3:
                words[i] = words[i][0] + re.sub(r'[aeiou]', '', words[i][1:])
        cand = ':' + '_'.join(words)
        if len(cand) > LIMIT or cand in ltaken:
            failed.append((name, cand))
            continue
        ltaken.add(cand)
        mapping[name] = cand
    return mapping, failed


def apply_map(mapping, apply):
    """Rewrite every occurrence, longest name first so no name is a prefix
    victim of a shorter one."""
    order = sorted(mapping, key=len, reverse=True)
    pat = re.compile('|'.join(re.escape(n) for n in order))
    touched = collections.Counter()
    for root, _, files in os.walk(ROOT):
        if any(p in root for p in SKIP):
            continue
        for f in sorted(files):
            if not f.endswith(SRC_EXT):
                continue
            p = os.path.join(root, f)
            text = open(p, errors='replace').read()
            new = pat.sub(lambda m: mapping[m.group(0)], text)
            if new != text:
                touched[p] = sum(1 for _ in pat.finditer(text))
                if apply:
                    open(p, 'w').write(new)
    return touched


def main(argv):
    apply = '--apply' in argv
    defs, local_defs = collect()
    mapping, failed = build_map(defs, local_defs)
    if '--map' in argv:
        for k in sorted(mapping):
            print(f'  {k:<26} -> {mapping[k]}')
    touched = apply_map(mapping, apply)
    print(f'{"APPLIED" if apply else "DRY RUN"}: {len(mapping)} symbols '
          f'renamed across {len(touched)} files, '
          f'{sum(touched.values())} occurrences')
    if failed:
        print(f"  NEEDS A HUMAN ({len(failed)}):", file=sys.stderr)
        for n, c in failed:
            print(f"    {n:<26} -> {c or '(no candidate)'}", file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
