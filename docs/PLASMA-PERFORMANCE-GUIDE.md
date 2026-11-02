# Writing fast PLASMA on a constrained 6502

Street-library companion: `learning:01M2WC5GHDY98HE3WTP834JB1V`.
Filed 2026-09-19; the library entry is the shared reference.

**Fast PLASMA work needs an explicit execution-and-memory cost model: remove redundant work, inspect emitted code and interfaces, and measure the complete workload as well as the hot loop.** [fact: the NAS experiments below demonstrate why each budget matters; the checklist is engineering guidance derived from them.]

This is a deliberate, durable companion to the chronological NAS evidence in [[01M2T5FCMBF6F1VM5WBS0DV5EJ]], not a replacement for that record. It also complements [[01M299EGQ6ZCCKJKP8G9MESS9C]]: that note establishes the single-bank capacity constraint; this guide covers execution costs, optimization experiments, ABI safety, profiling and AOT inference. The near-duplicate warning was reviewed and this separate scope is intentional. Scope: PLASMA on maux's constrained 6502/65C02 process environment. Measurements are from the verilogapple fast emulator, not physical hardware. These are not independently verified B-language lessons.

## 1. Learn the implementation's costs before choosing an optimization

[Guidance] Read the compiler's emitted bytecode/assembly, the VM and the runtime at the relevant call sites. Count helper invocations, argument construction, pointer loads, scans and allocations. Do not infer cost from the visual simplicity of a PLASMA expression.

[fact] In the pre-promotion NAS replacement, a source-bound lean trace attributed 855,376 cycles (8.86% of that whole command) to descriptor access, argument construction and transfer scaffolding. Native helpers therefore did not make their interfaces free. A private fixed-state ABI reduced this cost, but some helper stack arguments remain.

[Guidance] Consider a coarse-grained operation that keeps hot state together when repeated small interfaces dominate. Do not mechanically inline everything: include generated code size in the experiment.

## 2. Remove work before making the remaining work faster

[fact] NAS had repeated operand work, a separately linear local-name index and an extra counting walk used to size allocations. These were independent costs, not one generic interpreter penalty.

[fact] Stable per-symbol allocations, lazy local indexing, linked actual-size ERR/EQU records and paged opcode replay made the counting walk unnecessary. The selected implementation reads the source twice without retaining the source or moving existing symbol records. Replay records the pass1 decision; pass2 does not guess it again.

[Guidance] Look for repeated parsing, rescanning, sorting, sizing and initialization. Preserve semantic reasons for work: forward-reference sizing, symbol declaration order and provisional EQU values are not disposable redundancy. Removing a preparatory pass requires replacing its storage/capacity contract, not simply deleting the loop.

## 3. Treat executable bytes as part of the performance budget

[fact] NAS code and heap share the process address space. An additive native-loop experiment improved the five-real-input warm total from 74.25M to 61.15M cycles, but added 2,455 executable bytes. Initial heap fell from 13,146 to 10,691 bytes; staged assembly recipes rose from 453 to 496. The full world improved only from 9.80B to 9.65B cycles.

This is evidence that code growth and extra splitting can erase much of a local speedup, not a separate attribution of every world-build cycle.

[fact] The promoted design is 34,779 bytes with 12,069 initial heap bytes. It avoids the unconditional 1,152-byte retry reservation. Actual peak memory still depends on record/link/page costs. On the fixed real corpus it takes 50.75M warm cycles; the production graph takes 8.30B cycles with 458 assembly recipes and 118 links.

[Guidance] Record executable size, initial and peak heap, graph splitting, fixed-input timing and complete-workflow timing together. Update image-composer estimates when storage changes. Never accept an apparently faster world that silently omitted a utility.

## 4. Native escape paths need a complete contract

[fact, maux NAS only] The selected native context occupies $10-$65, with ten JMP call gates at $70-$8D. This is a private allocation checked against the actual VM/runtime/module closure, NOT a public PLASMA zero-page ABI.

[fact] A compiler-relocated seed reconstructs that state on every invocation, including warm starts. Native text remains immutable and position-independent in the exercised closure. Explicit continuations request expression evaluation, flushing and replay-page services without reparsing, defining labels twice or advancing PC/replay twice.

[Guidance] Specify scratch ownership, legal evaluation-stack positions, relocation, service/refusal behavior and the exact commit point. Test actual entry points, all legal stack positions, two load origins, guarded writes, poisoned state, cold/warm starts and refusal followed by successful reuse. Avoid assuming a newly loaded program is the only invocation pattern.

## 5. Keep PLASMA correctness traps visible during optimization

[fact] PLASMA words and ordinary relational comparisons are signed 16-bit. Heap addresses can have bit 15 set: use unsigned comparisons where the full address range is intended. Pointer indexing and length-prefixed string conventions also matter; see [[01M1ZR6GGDRNFVSSQ4HGSJE58K]] for the verified language traps.

[fact, this runtime] NAS now checks the unsigned allocation request against heapavail before heapalloc, preventing the runtime heap-addition wrap caught by a large fixup request. It also checks allocation failure before publishing or dereferencing a new record. This does NOT prove every caller's size multiplication or addition cannot overflow before reaching the allocator.

[Guidance] Validate size arithmetic as well as the allocation result. Exercise exhaustion and boundary failures, and require a correct different warm job afterward. A faster path that silently corrupts zero page is not an optimization.

## 6. Make measurements distinguish the questions being asked

[Guidance] Bind profiler symbols to the exact module and cooked binary being tested. Separate VM, native and kernel/other execution; do not call all VM time dispatch overhead or all kernel time disk latency. Keep startup, assembly windows, whole-command time and marginal throughput distinct.

[fact] Macro-led native routines exposed a symbolization error: their actual ACME entry labels preceded the first non-macro report row. Full-cycle fetch counting also required the previous row's SYNC and physical-bank tracking. Method and limitations: [[01M2KR4SK1HCPV5Q691EJZMTJG]].

[Guidance] Pair small/large synthetic workloads with representative real sources. Use independent output oracles and deliberate sabotage. Preserve binary hashes, input hashes, metadata and timing resolution. Current NAS gates compare all 85 utilities and the kernel independently, plus an empty second make.

## 7. Preserve failed experiments and keep AOT claims bounded

[fact] The fused reader passed 1,680 independent CPU cases but did not earn promotion. Its refined version matched the interface-only lean ratio (1.226x AS), worsened the symbolic ratio (1.193x versus 1.175x) and added 254 bytes. Correctness and fewer conceptual passes did not establish a speed win.

[fact] Promoted NAS is about 13% cheaper than AS on lean marginal cycles and near parity on the symbolic fixture. That is not a universal real-program comparison. The promoted five-input profile puts evalexpr + evalterm2 at about 5.1% of the sampled assembly window.

[Boundary, not an experimental result] That remaining expression budget cannot establish what AOT could have replaced BEFORE major hot paths moved to native code. Algorithmic work plus sufficiently good AOT matching this result remains UNPROVEN, not refuted. A fair experiment must compare equivalent algorithms and storage, compiler/ABI quality, executable size, heap, correctness and whole-workflow cost. Cooking a binary is not evidence that its PLASMA bytecode has been AOT-compiled.

## Practical starting checklist

1. Freeze representative inputs, exact artifacts and independent expected outputs.
2. Establish phase, call-count, code-size and heap budgets before changing code.
3. Name one mechanism, predict its effect, and test one bounded change.
4. Check boundaries, relocation, warm state and failed-operation recovery.
5. Recheck the whole workload and roster after any code/storage growth.
6. Preserve negative results and distinguish measurements from proposals.

## Provenance

Verified NAS work on 2026-09-18/19; source and reports rechecked 2026-09-19. maux: src/asm/nas.pla; src/plasma/rt.pla; docs/NAS-NATIVE-LOOP-EXPERIMENT.md; docs/NAS-MERLIN-PATH-COMPARISON.md; docs/NAS-TWO-PASS-REFACTOR.md; docs/NAS-PROMOTION-PROFILE.md; scripts/check_nas_grow_native.py; scripts/check_nas_grow_guest.py; scripts/profile_nas_hotspots.py; scripts/profile_nas_real_paths.py. Detailed artifact hashes, reproduction commands, limitations and corrected report counts are in [[01M2T5FCMBF6F1VM5WBS0DV5EJ]]. Historical line-start NASLOG counts undercounted interleaved make/child reports; do not reuse them as executed-command totals.

