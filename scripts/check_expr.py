#!/usr/bin/env python3
"""check_expr.py -- acceptance gate for `expr`
(src/bin/expr.s + src/bin/expr.eval.s, `make check-expr`).

Boots src/test/exprtest.s (a single maux process synthesized into aux
bank 1, real syscalls live) and drives exprtestb.s's 37-row case
table straight against EXPR_EVAL/EXPR_EXITCD -- 1 (pass) / 0 (fail)
per case at R_RESULTS, case count at R_NCASES, done flag at R_DONE
($AA success). A case that never ran leaves $EE. Same peek-the-
results-table shape as check_testev.py.

Phase 2 (added by the direct-spawn investigation, see exprtestb.s's
header): EXPR itself is spawned DIRECTLY (no `sh` -- it has no
quoting yet and cannot pass a literal `*`), stdout redirected to a
capture file, argv "2","*","3". This is the phase that was
originally attempted and dropped after a kernel ERR_INVAL whose root
cause (CWD_READ, src/kernel/sched.s, never selected aux bank 0
before reading the shared cwd table -- see that routine's own
comment) wasn't pinned down in time; it has since been found and
fixed, and this phase asserts the real fix's teeth: SPAWN succeeds,
the child's stdout capture reads back "6\\r" (2 * 3, proving the
literal `*` survived without `sh`), and R2_ERR stays 0.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_drive import MCPClient, SUPERVISOR, ROMS_DIR  # noqa: E402

R_RESULTS, R_NCASES, R_DONE = 0x1400, 0x1440, 0x1441

R2_STEP, R2_ERR, R2_DONE = 0x1500, 0x1501, 0x1502
R2_SPAWN_PID, R2_WAIT_STAT = 0x1503, 0x1504
R2_TRANS, R2_DATA = 0x1505, 0x1507
EXPECTED_OUTPUT = bytes([ord('6') | 0x80, 0x0D | 0x80])  # "6\r", high-bit

NCASE = 37

LABELS = [
    '3|4 (left truthy -> 3)',
    '0|5 (left falsy -> right 5)',
    '0|0 (both falsy -> 0, exit1)',
    '3&4 (both truthy -> left 3)',
    '0&4 (left falsy -> 0)',
    '4&0 (right falsy -> 0)',
    '3=3 (true)',
    '3=4 (false)',
    '3!=4 (true)',
    '3!=3 (false)',
    '3<4 (true)',
    '4<3 (false)',
    '3<=3 (true)',
    '4<=3 (false)',
    '4>3 (true)',
    '3>4 (false)',
    '3>=3 (true)',
    '3>=4 (false)',
    '2+3*4 = 14 (precedence, mul before add)',
    '2*3+4 = 10 (precedence, mul first operand)',
    '10-3 = 7',
    '3-3 = 0 (exit1)',
    '3-10 (unsigned underflow -> status 2)',
    '6*7 = 42',
    '100*1000 (overflow -> status 2)',
    '7/2 = 3',
    '7%2 = 1',
    '5/0 (division by zero -> status 3)',
    '5%0 (modulo by zero -> status 3)',
    '65535+1 (overflow -> status 2)',
    'abc+3 (non-numeric operand -> status 2)',
    'foo=foo (string equal, true)',
    'foo=bar (string equal, false)',
    'abc<abd (string less-than, true)',
    'foo|bar (string result "foo", exit0)',
    '3 4 (malformed, extra argument -> status 2)',
    '0 args (status 2)',
]
assert len(LABELS) == NCASE


def peek_aux1(client, addr, count=1):
    return client.call_tool('peek', {
        'addr': addr,
        'count': count,
        'bank': 'aux',
        'aux_bank': 1,
    })['bytes']


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else 'build/expr.po'
    if not os.path.exists(SUPERVISOR):
        print(f'error: mcp_supervisor not found at {SUPERVISOR}',
              file=sys.stderr)
        return 2
    if not os.path.exists(disk):
        print(f'error: {disk} not found -- run make expr-image first',
              file=sys.stderr)
        return 2

    env = dict(os.environ)
    env['VERILOGAPPLE_ROMS'] = ROMS_DIR
    client = MCPClient([SUPERVISOR], env)
    try:
        client.initialize()
        r = client.call_tool('reset', {'backend': 'fast'})
        print(f'[check-expr] reset -> {r}', file=sys.stderr)
        r = client.call_tool('mount_disk', {'path': os.path.abspath(disk)})
        print(f'[check-expr] mount_disk -> {r}', file=sys.stderr)
        if r.get('ok') is False:
            raise RuntimeError(f'mount_disk failed: {r}')

        done = 0
        done2 = 0
        for _ in range(500):
            client.call_tool('step', {'cycles': 200_000})
            done = peek_aux1(client, R_DONE)[0]
            done2 = peek_aux1(client, R2_DONE)[0]
            if done == 0xAA and done2 in (0xAA, 0xEE):
                break
        ncases = peek_aux1(client, R_NCASES)[0]
        res = peek_aux1(client, R_RESULTS, NCASE)
        print(f'[check-expr] done=${done:02X} ncases={ncases} '
              f'phase2_done=${done2:02X}', file=sys.stderr)

        if done != 0xAA:
            print(f'[check-expr] FAIL: harness never finished '
                  f'(done=${done:02X}) -- did it boot?', file=sys.stderr)
            return 1
        if ncases != NCASE:
            print(f'[check-expr] FAIL: image reported {ncases} cases, '
                  f'expected {NCASE}', file=sys.stderr)
            return 1

        bad = []
        for i, label in enumerate(LABELS):
            if res[i] != 1:
                bad.append(label)
                state = 'wrong result' if res[i] == 0 else 'never ran'
                print(f'  FAIL {label}: {state}', file=sys.stderr)
        if bad:
            print(f'\n[check-expr] FAIL ({len(bad)}/{NCASE})',
                  file=sys.stderr)
            return 1

        print(f'[check-expr] PASS -- expr: {NCASE}/{NCASE} cases '
              f'(every operator, both outcomes per comparison, '
              f'precedence both directions, overflow, division and '
              f'modulo by zero, string comparison, malformed '
              f'expressions)')

        # -- Phase 2: EXPR spawned directly (no sh), argv "2","*","3".
        step2 = peek_aux1(client, R2_STEP)[0]
        err2 = peek_aux1(client, R2_ERR)[0]
        spawn_pid = peek_aux1(client, R2_SPAWN_PID)[0]
        wait_stat = peek_aux1(client, R2_WAIT_STAT)[0]
        trans = peek_aux1(client, R2_TRANS, 2)
        trans_n = trans[0] | (trans[1] << 8)
        data = bytes(peek_aux1(client, R2_DATA, min(trans_n, 32)))
        print(f'[check-expr] phase2: step=${step2:02X} err=${err2:02X} '
              f'spawn_pid={spawn_pid} wait_stat=${wait_stat:02X} '
              f'trans={trans_n} data={data!r}', file=sys.stderr)

        p2fail = []
        if done2 != 0xAA:
            p2fail.append(f'harness did not finish (done=${done2:02X}, '
                           f'step=${step2:02X}, err=${err2:02X})')
        if spawn_pid == 0:
            p2fail.append('direct SPAWN(EXPR) returned pid 0')
        if data != EXPECTED_OUTPUT:
            p2fail.append(f'stdout capture mismatch: expected '
                           f'{EXPECTED_OUTPUT!r} ("6\\r", i.e. 2*3 with '
                           f'the literal `*` surviving without sh), '
                           f'got {data!r}')
        if p2fail:
            for f in p2fail:
                print(f'[check-expr] FAIL (phase 2): {f}', file=sys.stderr)
            return 1

        print('[check-expr] PASS (phase 2) -- EXPR spawned directly, '
              'literal `*` survived, stdout capture reads "6"')
        return 0
    finally:
        client.close()


if __name__ == '__main__':
    raise SystemExit(main())
