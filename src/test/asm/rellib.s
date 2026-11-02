*---------------------------------------------------------------
* rellib.s -- nas L1b fixture, library half (docs/AS-PLASMA.md).
* Exports LIBGREET, the symbol relmain.s's `EXT` line references
* across the link. A second, independently assembled REL module.
*---------------------------------------------------------------
 REL
LIBGREET ENT
 LDA #$0A
 RTS
