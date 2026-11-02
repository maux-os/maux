*---------------------------------------------------------------
* spawnpl.s -- the PLAIN twin of spawnbl.s (KFIX5), `put` by
* every manifest that carries no builtin images (MAUXPLAY and
* every harness whose table was only ever dummies): a spawn path
* is always a file.
*
* PRC_BLTN   carry CLEAR: not a builtin.
* PRC_LD_ANY the file loader, tail-called.
*
* What it saves is the lookup, the embedded-image loader, the
* K_BLTN table and the dummy images the harnesses linked "to
* stay link-compatible", less these four bytes and the hook
* at PRC_SPAWN: measured -152 B in every plain image (the
* builtin twin costs +3 B over the old inline form).
*---------------------------------------------------------------
PRC_BLTN    clc
            rts
PRC_LD_ANY  jmp   PRC_LD_FL_IMG
