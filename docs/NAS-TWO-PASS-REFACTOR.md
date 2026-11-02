# NAS private native state and incremental two-pass storage

Status: promoted to canonical src/asm/nas.pla and the normal Makefile build,
2026-09-19. The promoted build runs the full world in 8.30B cycles (see
[NAS.md](NAS.md)).
The sections below retain the original candidate experiment evidence.
This implements the priorities measured in a comparison of the NAS and Merlin
assembly paths.

## Implementation

The native instruction engine now uses private process zero page:

| Region | Use |
| --- | --- |
| $10-$65 | Native context, including continuation and evaluation results |
| $70-$8D | Ten initialized JMP call gates |
| $06-$09, $9E, $E7-$E8 | Existing shared native-helper scratch |
| $A0-$DF | Existing PLASMA evaluation stack, unchanged |

`initloop` copies the relocated seed and builds the gates on EVERY program
invocation. No native text changes, no new loader relocation, no compiler
change, and no general AOT compiler. Direct context accesses and fixed
call gates replace repeated descriptor-pointer loading and indirect-call
argument lookup. The general helper evaluation-stack ABI remains at helper
boundaries; this is not a claim that all argument construction vanished.

The window is private to this NAS implementation, not a new public PLASMA
ABI. The maux VM, runtime and linked module sources were checked for their
zero-page ownership. Independent two-origin CPU tests enforce write guards;
cold/warm guest tests exercise initialization and services. Do not assume
an arbitrary third-party PLASMA native module preserves this window.

Pass0 and its native scan0 are removed from the generated source. NAS now
walks the source twice:

- Symbols allocate one stable record plus its counted name when first
  needed. The first nine record bytes and hash chains are unchanged; two
  added bytes link declaration order for byte-identical REL dictionaries.
- Local-name ambiguity records allocate individually. Their 128-bucket
  index is allocated only when a local definition first needs it.
- Opcode replay uses 260-byte pages: next pointer, used count, 256 bytes.
  Native control requests page allocation before changing PC/count and
  resumes the already-selected instruction. Pass2 advances pages without
  reparsing the line or redefining/checking its label twice.
- Deferred ERR records and forward-EQU retry records are pointer-linked,
  allocated at their actual text size. The existing 16-retry ceiling and
  fixed-point semantics remain. There is no unconditional 1,152-byte retry
  reservation.
- Allocation checks the unsigned request against available heap BEFORE
  calling the runtime allocator, preventing a large request from wrapping
  the runtime's 16-bit heap addition. Failed EXT insertion is checked before
  dereferencing the returned symbol pointer.

No moving/reallocating symbol table, no whole-source retention, and no
per-instruction allocation. Replay page slack is at most 255 payload bytes
plus four metadata bytes per page; symbol traversal costs two bytes per
record. These costs are real, not free memory.

## Measured results

Fast-emulator cycles, not physical hardware. Same frozen real-source image
and existing independent byte contracts.

| Metric | Production | Previous replacement | New two-pass candidate |
| --- | ---: | ---: | ---: |
| Cooked bytes | 33,702 | 35,674 | 34,779 |
| Initial heap bytes | 13,146 | 11,174 | 12,069 |
| Five real inputs, warm Mcycles | 74.25 | 58.60 | 50.75 |
| Lean warm marginal NAS/AS cost | 2.301x | 1.301x | 0.871x |
| Symbolic warm marginal NAS/AS cost | 1.921x | 1.237x | 1.018x |
| Full native world, billion cycles | 9.80 | 9.20 | 8.25 |
| Staged assembly recipes | 453 | 481 | 453 |
| Executed successful NAS reports | 275 | 298 | 275 |

The fixed real-source corpus takes 31.6% fewer cycles than production and
13.4% fewer than the previous replacement. Lean marginal assembly is 12.9%
fewer cycles than AS; the symbol-heavy marginal result is approximately
parity, not a general claim that NAS is faster than AS. Cold symbolic ratio
is 1.009x; the cold/warm difference is one 50K-cycle polling quantum.
The entire matched lean warm command takes 7,140,801 cycles versus AS
8,289,932 (13.9% fewer); the full trace contains no pass0 execution. This
whole-command ratio is distinct from the small/large marginal slope.
All eight corpus cases reproduce identical cold/warm timings, object bytes
and metadata in an immediate complete repeat.

| Real input | New warm Mcycles |
| --- | ---: |
| ECHOM | 3.65 |
| SYSCALLSRL | 4.55 |
| GREPM | 13.95 |
| VIM | 13.75 |
| SHM | 14.85 |

Native-interface ablation, still retaining pass0: 35,395 bytes; lean marginal
ratio 1.226x, symbolic 1.175x. Removing preliminary counting is what crosses
the lean performance gap; interface cleanup alone does not.

The fused-reader experiment is NOT enabled. Its first transactional version
regressed lean marginal ratio to 1.312x. Removing redundant token copying
and character loads recovered 1.226x, equal to the interface-only result,
but symbolic cost was worse (1.193x) and it added 254 bytes. It passes 1,680
independent parser/boundary cases, but does not earn its space or complexity.
The existing reader remains in the selected build. The source and opt-in
flag preserve the measured experiment rather than hiding the negative result.

## Whole-world verification

The standard historical composer still models precounted contiguous
storage. Applying it unchanged to the new binary selected a graph that
skipped SH for its argument-count limit. That is NOT accepted as a green
world. The fixed-graph runner composes using a PRIVATE snapshot of current
production NAS, then installs the candidate before booting. It asserts that
the only intentional exclusion is AS, so all 85 utilities must be present.

The candidate must run the unchanged production graph: 453 staged assembly
recipes and 118 links. No extra source splitting is allowed to hide memory
regressions. An initial attempt with unconditional retry reservation ran
out of memory on DIFF; incremental retry storage removes that reservation.

The FINAL guarded binary completes in approximately 8.25 billion cycles:
15.8% fewer than production's 9.80B on the same staged graph. All 85
utilities and the 28,921-byte kernel are byte-identical to independent
merlin32 references. MK2OUT is empty. The installed NAS readback equals
the measured candidate. There are 275 executed successful NAS reports,
matching production, not the 453 staged recipes. This is one complete run
of the final binary, with 50M-cycle completion resolution, not a precise
statistical timing guarantee. Do not count the earlier partial run as a
successful world.

The executable still has 1,077 fewer initial heap bytes than production.
Removing the unconditional retry reserve recovers 1,152 runtime heap bytes
on inputs without forward-EQU retries, but per-record/page costs vary with
input. Initial heap and peak assembly memory are distinct quantities.

## Verification and reproduction

- 1,780 independent instruction/control cases, plus 30 multi-page replay,
  flush and page-refusal cases through 1,025 instructions, at two origins.
  Code bytes are origin-independent and unchanged by execution; write and
  evaluation-stack guards hold. Actual-entry RTS sabotage is rejected.
- 64 state-initialization cases cover every legal one-argument stack slot
  and poisoned memory at two origins.
- Seven guest allocation-exhaustion/addition-wrap inputs cover symbols,
  EXT insertion, locals, replay, ERR and fixup storage. Every failure exits
  nonzero with an allocation diagnostic and creates no object. A different
  warm 513-instruction assembly after every failure matches literal bytes.
- A 16-deep forward-EQU chain matches independent expected bytes; the 17th
  retry is refused, followed by a successful warm chain assembly.
- Existing guest boundary and linked REL contracts at $0800/$20F9 pass;
  all 16 flat cold/warm objects match fresh merlin32; all eight real/local
  cold/warm corpus pairs match the frozen production bytes and metadata.
- check-dialect and check-modules pass. The original replacement's oracle
  remains separate and unchanged in semantics.

```sh
python3 scripts/build_nas_grow.py --output-dir build/nas-grow-safe
python3 scripts/check_nas_grow_native.py
python3 scripts/check_nas_loop.py --build-dir build/nas-grow-safe
python3 scripts/check_nas_grow_guest.py --build-dir build/nas-grow-safe
python3 scripts/check_nas_fixed_world.py --build-dir build/nas-grow-safe
```

Historical promotion boundary (now resolved; see linked promotion report):
default production builds were deliberately untouched. The storage-aware
production composer and canonical source integration are not supplied by
this opt-in source transform. Do not promote merely by copying nas.cut over
the release binary; retain the checked source/build identity and reconcile
the composer with the new storage model first.

Final candidate SHA256:
6067d14fc4200d3ef5faa4742b72e12d8394ba12d9961d1366f491340b96f2a6.
Former production baseline:
3f0e41166b3b88784ec83d7fb82e568ecf022333a5270019b0840348e992fc11.

Artifacts: build/nas-grow-safe-{build,native,guest,oom,world,perf,flat,paths}.log
and corresponding performance JSON; build/nas-grow-safe/fixed-world-plan.json
and fixed-world-method.json. Existing emulator shutdown mutex exceptions
are not correctness evidence; exit status, independent persistent bytes and
trace/count assertions are the acceptance checks.

Promotion correction: the historical table's executed-report counts used
line-start matching and undercounted reports interleaved with make echoes.
The saved fixed-world NASLOG contains 320 successful reports, not 275;
the replacement world contains 348, not 298. This changes neither timings
nor staged recipes nor independent byte comparisons. The new production
world contains 325 reports and takes 8.30B cycles with 458 recipes.
The build_nas_loop/replace/state/grow source transformers are retired and
fail with directions to the normal build; their source fragments remain
historical experiment evidence, not production inputs.

Library notes: learning:01M2T5FCMBF6F1VM5WBS0DV5EJ supplied the measured
budgets and heap/world constraints; learning:01M2KR4SK1HCPV5Q691EJZMTJG
supplied trace alignment; learning:01M1ZYV78A18R5EJDC83GSG4EJ explained why
Merlin's linear lookup is not a pattern to copy. New verified findings are
deposited back into the performance learning.
