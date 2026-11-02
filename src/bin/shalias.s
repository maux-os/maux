*---------------------------------------------------------------
* shalias.s -- the LOW-resident message strings for sh's
* `alias`/`unalias`/`hash`/`fc` builtins and the alias expander
* (all CODE in src/bin/shsgali.s, the $E000 segment). `put` by
* src/bin/sh.s after shblt3.s, the same pairing as shblt3.s/
* shsgblt.s: everything a WRITE ever sees must sit below $D000
* (COPYIN_ENTRY refuses a process address >= $D000, learning:
* 01M2MCYEXW7JA7ZPZ4F7GC2217). docs/SH-ALIAS-NOTES.md.
*---------------------------------------------------------------
ALI_LONG_M  asc   "sh: alias: expansion too long"
            dfb   $8D,0
ALI_FULL_M  asc   "sh: alias: table full (8)"
            dfb   $8D,0
ALI_BADN_M  asc   "sh: alias: bad name"
            dfb   $8D,0
ALI_RESV_M  asc   "sh: alias: reserved word"
            dfb   $8D,0
ALI_VLNG_M  asc   "sh: alias: value too long (31)"
            dfb   $8D,0
ALI_PFX_M   asc   "alias: "
            dfb   0
UNA_PFX_M   asc   "unalias: "
            dfb   0
UNA_USE_M   asc   "sh: unalias: usage: unalias [-a] name..."
            dfb   $8D,0
HSH_PFX_M   asc   "hash: "
            dfb   0
FC_NSUP_M   asc   "sh: fc: not supported (history is the "
            asc   "console's)"
            dfb   $8D,0
ALI_SPL_M   asc   "sh: alias before a loop head on one line"
            dfb   $8D,0
