*---------------------------------------------------------------
* sysvroot.s -- SC_VROOT and SC_ONLINE for a program that wants
* those two syscalls and not the whole of readdir.s (which owns
* them for everything else). `bye` re-attaches a loop image with
* them (docs/LOOP-S2.md S4). Its labels are SC_B*, so it can sit
* beside readdir.s without a collision.
*   SC_BVROOT  A/X = a 4-byte parm {op, ptr, arg}
*   SC_BONLINE A/X = {2, unit_num, buffer ptr}
*---------------------------------------------------------------
SC_BVROOT   ldy   #SYS_VROOT
            jsr   $FF00
            rts
SC_BONLINE  ldy   #SYS_ONLINE
            jsr   $FF00
            rts
