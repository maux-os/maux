*---------------------------------------------------------------
* local.s -- nas :local fixture (docs/AS-PLASMA.md, task #21).
*
* Self-contained: ONLY :local labels + basic opcodes/ORG, so it
* isolates :local resolution from every other directive.
* Exercises merlin32's MEASURED :local resolution (scratchpad
* tests vs merlin32 v1.1.10, task report):
*   - within-zone :local, BACKWARD ref (:back in zone START)
*   - within-zone :local, FORWARD ref (:fwd in zone START)
*   - the SAME :local name (:back) reused in a DIFFERENT zone
*     (MID), each zone binding its OWN definition
*   - a :local name (:once) defined in exactly ONE zone (MID)
*     and referenced from a THIRD zone (TAIL) with no :once of
*     its own -- resolves by whole-file uniqueness (merlin32's
*     own "ozunid"/rename split -- see task report)
*
* merlin32 assembling this file is the oracle; nas's flat
* output must be byte-identical to build/local.bin.
*---------------------------------------------------------------
        org   $2000

start   lda   #1
:back   inx
        bne   :back          ;within-zone backward
        bne   :fwd           ;within-zone forward
        inx
:fwd    rts

mid     lda   #2
:back   dex                  ;same name, other zone
        bne   :back          ;binds MID's own :back
:once   nop
        rts

tail    lda   #3
        dey
        bne   :once          ;cross-zone, unique name
        rts

* Hash collisions: these names all hash to 20 (128 buckets).
* Keep names distinct at chain head, middle and tail.
* Second zone makes :hae7 ambiguous; the others stay unique.
hashone nop
        jmp   :ha26
:hae7   dfb   $11
:haf2   dfb   $22
:ha26   dfb   $33
:ha31   dfb   $44
:hba2   dfb   $55
        da    :hae7,:haf2,:ha26,:ha31,:hba2
hashtwo nop
        jmp   :hae7
:hae7   dfb   $66
        da    :hae7,:haf2,:ha26,:ha31,:hba2
hashend da    :haf2,:ha26,:ha31,:hba2

* Raw case is significant for locals, as for global names.
caseone nop
:Case   dfb   $77
:case   dfb   $88
        da    :Case,:case
casetwo da    :Case,:case
