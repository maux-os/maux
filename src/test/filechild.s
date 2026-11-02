*---------------------------------------------------------------
* filechild.s -- tiny process image loaded from a ProDOS file by
* the file-backed spawn integration gate.
*
* IT LOADS AT $2000, NOT AT $0800, AND THAT IS THE POINT (S9
* L3b, 2026-08-29). The loader HONOURS a binary's ProDOS
* aux_type as its load address -- the BASIC.SYSTEM convention --
* and every other binary in this tree is aux $0800, so nothing
* would have told the difference between honouring the field and
* ignoring it. This one image is staged at aux $2000 by
* build_fileprocess_image.py and build_sticky_image.py; a loader
* that ignored aux would drop it at $0800 and jump there, into
* whatever the bank last held, and the wait status the harness
* asserts would not come back. Sabotage-verified: pinning the
* loader's destination back to LOAD_BASE turns check-fileprocess
* and check-sticky red.
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/fchild.bin
            typ   $00

            put   ../../inc/sc.proc.equ

PARM        equ   $0900

START       lda   #$55
            sta   PARM
            lda   #<PARM
            ldx   #>PARM
            ldy   #SYS_EXIT
            jsr   $FF00
:park       bra   :park
