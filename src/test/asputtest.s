*---------------------------------------------------------------
* asputtest.s -- check-as's PUT case (docs/AS-PUT.md). The point
* is the `put` line: until AS_GOREAD existed, `as` could not
* service one at all, and every real maux unit has several.
*
* Deliberately NOT trivial. The included half defines a label
* this half references FORWARD, so a put that loaded the wrong
* bytes -- or loaded them and lost the parent's source pointer
* on the way back -- cannot assemble to the same object by
* accident. The `rts` after the put proves the parent RESUMED:
* ENDPUT has to restore SPNT from SPSAV, and if it does not,
* this line is never seen.
*---------------------------------------------------------------
            org   $2000
START       lda   #$07
            jsr   PUTSUB
            sta   $2020
            put   asputinc.s
            rts
