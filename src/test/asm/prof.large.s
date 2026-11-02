*----------------------------------------------------------
* prof.large.s -- nas-vs-as throughput fixture
* (N=100 blocks). docs/AS-PROFILE.md.
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
* ---- 100 repeating blocks -------------------------------
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
L0011       lda   #$01
            sta   $10
            dex
            bne   L0011
L0012       lda   #$01
            sta   $10
            dex
            bne   L0012
L0013       lda   #$01
            sta   $10
            dex
            bne   L0013
L0014       lda   #$01
            sta   $10
            dex
            bne   L0014
L0015       lda   #$01
            sta   $10
            dex
            bne   L0015
L0016       lda   #$01
            sta   $10
            dex
            bne   L0016
L0017       lda   #$01
            sta   $10
            dex
            bne   L0017
L0018       lda   #$01
            sta   $10
            dex
            bne   L0018
L0019       lda   #$01
            sta   $10
            dex
            bne   L0019
L0020       lda   #$01
            sta   $10
            dex
            bne   L0020
L0021       lda   #$01
            sta   $10
            dex
            bne   L0021
L0022       lda   #$01
            sta   $10
            dex
            bne   L0022
L0023       lda   #$01
            sta   $10
            dex
            bne   L0023
L0024       lda   #$01
            sta   $10
            dex
            bne   L0024
L0025       lda   #$01
            sta   $10
            dex
            bne   L0025
L0026       lda   #$01
            sta   $10
            dex
            bne   L0026
L0027       lda   #$01
            sta   $10
            dex
            bne   L0027
L0028       lda   #$01
            sta   $10
            dex
            bne   L0028
L0029       lda   #$01
            sta   $10
            dex
            bne   L0029
L0030       lda   #$01
            sta   $10
            dex
            bne   L0030
L0031       lda   #$01
            sta   $10
            dex
            bne   L0031
L0032       lda   #$01
            sta   $10
            dex
            bne   L0032
L0033       lda   #$01
            sta   $10
            dex
            bne   L0033
L0034       lda   #$01
            sta   $10
            dex
            bne   L0034
L0035       lda   #$01
            sta   $10
            dex
            bne   L0035
L0036       lda   #$01
            sta   $10
            dex
            bne   L0036
L0037       lda   #$01
            sta   $10
            dex
            bne   L0037
L0038       lda   #$01
            sta   $10
            dex
            bne   L0038
L0039       lda   #$01
            sta   $10
            dex
            bne   L0039
L0040       lda   #$01
            sta   $10
            dex
            bne   L0040
L0041       lda   #$01
            sta   $10
            dex
            bne   L0041
L0042       lda   #$01
            sta   $10
            dex
            bne   L0042
L0043       lda   #$01
            sta   $10
            dex
            bne   L0043
L0044       lda   #$01
            sta   $10
            dex
            bne   L0044
L0045       lda   #$01
            sta   $10
            dex
            bne   L0045
L0046       lda   #$01
            sta   $10
            dex
            bne   L0046
L0047       lda   #$01
            sta   $10
            dex
            bne   L0047
L0048       lda   #$01
            sta   $10
            dex
            bne   L0048
L0049       lda   #$01
            sta   $10
            dex
            bne   L0049
L0050       lda   #$01
            sta   $10
            dex
            bne   L0050
L0051       lda   #$01
            sta   $10
            dex
            bne   L0051
L0052       lda   #$01
            sta   $10
            dex
            bne   L0052
L0053       lda   #$01
            sta   $10
            dex
            bne   L0053
L0054       lda   #$01
            sta   $10
            dex
            bne   L0054
L0055       lda   #$01
            sta   $10
            dex
            bne   L0055
L0056       lda   #$01
            sta   $10
            dex
            bne   L0056
L0057       lda   #$01
            sta   $10
            dex
            bne   L0057
L0058       lda   #$01
            sta   $10
            dex
            bne   L0058
L0059       lda   #$01
            sta   $10
            dex
            bne   L0059
L0060       lda   #$01
            sta   $10
            dex
            bne   L0060
L0061       lda   #$01
            sta   $10
            dex
            bne   L0061
L0062       lda   #$01
            sta   $10
            dex
            bne   L0062
L0063       lda   #$01
            sta   $10
            dex
            bne   L0063
L0064       lda   #$01
            sta   $10
            dex
            bne   L0064
L0065       lda   #$01
            sta   $10
            dex
            bne   L0065
L0066       lda   #$01
            sta   $10
            dex
            bne   L0066
L0067       lda   #$01
            sta   $10
            dex
            bne   L0067
L0068       lda   #$01
            sta   $10
            dex
            bne   L0068
L0069       lda   #$01
            sta   $10
            dex
            bne   L0069
L0070       lda   #$01
            sta   $10
            dex
            bne   L0070
L0071       lda   #$01
            sta   $10
            dex
            bne   L0071
L0072       lda   #$01
            sta   $10
            dex
            bne   L0072
L0073       lda   #$01
            sta   $10
            dex
            bne   L0073
L0074       lda   #$01
            sta   $10
            dex
            bne   L0074
L0075       lda   #$01
            sta   $10
            dex
            bne   L0075
L0076       lda   #$01
            sta   $10
            dex
            bne   L0076
L0077       lda   #$01
            sta   $10
            dex
            bne   L0077
L0078       lda   #$01
            sta   $10
            dex
            bne   L0078
L0079       lda   #$01
            sta   $10
            dex
            bne   L0079
L0080       lda   #$01
            sta   $10
            dex
            bne   L0080
L0081       lda   #$01
            sta   $10
            dex
            bne   L0081
L0082       lda   #$01
            sta   $10
            dex
            bne   L0082
L0083       lda   #$01
            sta   $10
            dex
            bne   L0083
L0084       lda   #$01
            sta   $10
            dex
            bne   L0084
L0085       lda   #$01
            sta   $10
            dex
            bne   L0085
L0086       lda   #$01
            sta   $10
            dex
            bne   L0086
L0087       lda   #$01
            sta   $10
            dex
            bne   L0087
L0088       lda   #$01
            sta   $10
            dex
            bne   L0088
L0089       lda   #$01
            sta   $10
            dex
            bne   L0089
L0090       lda   #$01
            sta   $10
            dex
            bne   L0090
L0091       lda   #$01
            sta   $10
            dex
            bne   L0091
L0092       lda   #$01
            sta   $10
            dex
            bne   L0092
L0093       lda   #$01
            sta   $10
            dex
            bne   L0093
L0094       lda   #$01
            sta   $10
            dex
            bne   L0094
L0095       lda   #$01
            sta   $10
            dex
            bne   L0095
L0096       lda   #$01
            sta   $10
            dex
            bne   L0096
L0097       lda   #$01
            sta   $10
            dex
            bne   L0097
L0098       lda   #$01
            sta   $10
            dex
            bne   L0098
L0099       lda   #$01
            sta   $10
            dex
            bne   L0099
L0100       lda   #$01
            sta   $10
            dex
            bne   L0100
*
* ---- data section --------------------------------------
*
DATA        dfb   $11,$22,$33,$44
            asc   "PROF DATA LINE"
            hex   0102030405060708
            ds    16
ENDMARK     equ   *-DATA
            dfb   $00
