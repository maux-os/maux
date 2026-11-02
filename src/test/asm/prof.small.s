*----------------------------------------------------------
* prof.small.s -- nas-vs-as throughput fixture
* (N=10 blocks). docs/AS-PROFILE.md.
*
* Pure merlin32 cap Merlin-8 intersection: left-to-right
* operand eval, no forward-ref EQUs, no negative DS, no
* DCI/STR quoted items (HACKING.md dialect family; docs/
* AS-PLASMA.md sec 6). Every line <= 64 chars -- real
* Merlin-8 rejects longer ones with "Operand too long"
* (scripts/check_modules.py MERLIN_LINE_LIMIT), measured
* the hard way while building this fixture.
*
* Each block is a UNIQUE label + 4 insns + a backward
* branch to its own label, so the symbol table grows
* with block count N -- the point of the exercise.
*----------------------------------------------------------
            lst   off
            xc
            org   $2000
*
* ---- header constants (plain, no forward refs) --------
*
HDRC1       equ   $01
HDRC2       equ   $02
HDRC3       equ   $03
HDRC4       equ   $04
*
* ---- 10 repeating blocks -------------------------------
*
L0001       lda   #$01
            sta   $10
            dex
            bne   L0001
L0002       lda   #$01
            sta   $10
            dex
            bne   L0002
L0003       lda   #$01
            sta   $10
            dex
            bne   L0003
L0004       lda   #$01
            sta   $10
            dex
            bne   L0004
L0005       lda   #$01
            sta   $10
            dex
            bne   L0005
L0006       lda   #$01
            sta   $10
            dex
            bne   L0006
L0007       lda   #$01
            sta   $10
            dex
            bne   L0007
L0008       lda   #$01
            sta   $10
            dex
            bne   L0008
L0009       lda   #$01
            sta   $10
            dex
            bne   L0009
L0010       lda   #$01
            sta   $10
            dex
            bne   L0010
*
* ---- data section --------------------------------------
*
DATA        dfb   $11,$22,$33,$44
            asc   "PROF DATA LINE"
            hex   0102030405060708
            ds    16
ENDMARK     equ   *-DATA
            dfb   $00
