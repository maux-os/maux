* forward.s -- frozen NAS baseline for pass-1 sizing replay.
* ORG $00F0: LDA FWD occupies $F0-$F2, RTS is $F3, and FWD is
* $F4.
* merlin32 emits A5 F3 60 EA after resolving and resizing. NAS's
* accepted
* streaming contract retains the pass-1 unresolved absolute
* choice AD F4 00
* 60 EA. The expected bytes are intentionally frozen, not copied
* from NAS.
        org   $00F0
        lda   FWD
        rts
FWD     nop
