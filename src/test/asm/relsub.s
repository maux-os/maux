*---------------------------------------------------------------
* relsub.s -- spliced into relmain.s by `PUT relsub` (nas L1b
* PUT
* fixture, docs/AS-PLASMA.md). Defines LOCALCALL, referenced
* FORWARD from relmain.s's own code (matches
* src/test/asputtest.s's
* precedent).
*---------------------------------------------------------------
LOCALCALL LDA #$05
 RTS
