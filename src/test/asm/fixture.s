*---------------------------------------------------------------
* fixture.s -- nas L0 first-light fixture (docs/AS-PLASMA.md).
*
* Exercises exactly the L0 coverage, no more:
*   addressing modes: immediate, zero page, absolute, absolute,X
*   absolute,Y, implied, accumulator, relative branch forward AN
*   backward.
*   directives: ORG, EQU, DS, DFB, ASC.
*   labels with a FORWARD reference (FWD, DATA) and a BACKWARD
*   reference (BACK).
*
* merlin32 assembling this file is the oracle; nas's flat output
* must be byte-identical to build/fixture.bin.
*---------------------------------------------------------------
            org   $2000

ZPLOC       equ   $80
CONST       equ   $05

START       lda   #CONST         ;immediate
            sta   ZPLOC          ;zero page
            lda   DATA           ;absolute
            sta   DATA,x         ;absolute,x
            lda   DATA,y         ;absolute,y
            clc                  ;implied
            rol   a              ;accumulator
            bcc   FWD            ;forward branch
            nop
FWD         lda   #$00
BACK        dex
            bne   BACK           ;backward branch
            rts

DATA        dfb   $11,$22,$33
            asc   'HI'
            ds    4
            dfb   $00
