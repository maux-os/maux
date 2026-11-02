*----------------------------------------------------------
* profleanlarge.s -- symbol-LIGHT nas-vs-as per-line
* throughput fixture (N=100 blocks). docs/AS-PROFILE.md.
*
* Isolates the PURE per-line language/VM cost from the
* symbol table: the repeating block below declares NO
* label and references NO symbol -- plain zp/immediate
* operands only -- so symbol-table work stays CONSTANT
* (header + tail, same both sizes) regardless of N. Same
* merlin32 cap Merlin-8 dialect intersection rules as
* prof.small.s/prof.large.s (HACKING.md dialect family;
* docs/AS-PLASMA.md sec 6); every line <= 64 chars.
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
* ---- 100 repeating LABEL-FREE, SYMBOL-FREE blocks ------
*
START       lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
            lda   #$01
            sta   $10
            inc   $11
            nop
*
* ---- data section --------------------------------------
*
DATA        dfb   $11,$22,$33,$44
            asc   "PROF DATA LINE"
            hex   0102030405060708
            ds    16
ENDMARK     equ   *-DATA
            dfb   $00
