*---------------------------------------------------------------
* syssleep.s -- SC_SLPUNTIL, for the one program that sleeps
* (`sleep`), in its own module so no other program pays for it
* (sysvroot.s is the precedent).
*   SC_SLPUNTIL  A/X = a 4-byte parm, the absolute tick count
*   to sleep until. Carry set + A = ERR_NOSYS when there is no
*   tick (COOP or unprobed), ERR_INTR for a held signal.
*---------------------------------------------------------------
SC_SLPUNTIL
            ldy   #SYS_SLPUNTIL
            jsr   $FF00
            rts
