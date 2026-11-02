#!/usr/bin/env python3
"""Literal layout oracles for the production NAS image composer's budget."""
import build_nas_librel_image as model


def main():
    # Fixed buffers 2048, hash 256, one replay page 260, fixup terminator
    # 1, model slack 64. No unconditional retry array or local index.
    empty = 2629
    assert model.memory_model('') == empty
    for count, pages in ((0, 1), (1, 1), (255, 1), (256, 1),
                         (257, 2), (512, 2), (513, 3)):
        assert model.memory_model(' nop\n' * count) == empty + 260 * (pages - 1)
    assert model.memory_model('L nop\n') == empty + 13
    assert model.memory_model(':L nop\n') == empty + 14 + 6 + 256
    assert model.memory_model(':L nop\n:M nop\n') == empty + 28 + 12 + 256
    assert model.memory_model('E ext\n') == empty + 13
    assert model.memory_model(' err 0\n') == empty + 8
    assert model.memory_model('A equ 1\nB equ A\n') == empty + 26
    assert model.memory_model('A equ B\nB equ 1\n') == empty + 26 + 10
    assert model.memory_model('A equ B\nC equ A\nB equ 1\n') == empty + 39 + 20
    assert model.memory_model('A equ $AB\n') == empty + 13
    assert model.memory_model(' lda #1\n sta $10\n') == empty + 8
    assert model.memory_model(' bne *\n asl a\n rts\n') == empty
    assert model.memory_model(' lda A\n') == empty + 4
    assert model.memory_model(' dfb "A,B",0\n da 1,2,3\n') == empty + 20
    assert model.memory_model(' ds 1000\n asc "ABC"\n ddb 1\n') == empty
    assert model._line_cost('L lda #1') == 18
    assert model._line_cost(' bne *') == 1
    assert model.NAS_SPLIT_RESERVE == 2884
    model.assert_complete_world(range(85), ['kernel'], {'AS': 'pinned'})
    for utils, kernels, skipped in ((range(84), ['kernel'], {'AS': 'pinned'}),
            (range(85), [], {'AS': 'pinned'}),
            (range(85), ['kernel'], {'AS': 'pinned', 'SH': 'too many args'})):
        try:
            model.assert_complete_world(utils, kernels, skipped)
        except AssertionError:
            pass
        else:
            raise AssertionError('incomplete roster sabotage was accepted')
    print('PASS: incremental heap layout, replay boundaries, lazy indexes, '
          'linked retry/ERR, instruction and numeric-list fixup budgets; '
          'missing utility/kernel and skipped-SH sabotage rejected')


if __name__ == '__main__':
    main()
