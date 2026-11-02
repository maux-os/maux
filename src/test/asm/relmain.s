*---------------------------------------------------------------
* relmain.s -- nas L1b fixture (docs/AS-PLASMA.md): PUT + REL +
* EXT, in one module, proven by assemble -> link -> run.
*
* `PUT relsub` splices relsub.s (LOCALCALL), referenced FORWARD
* from START -- the same non-trivial shape src/test/asputtest.s
* uses (PUTSUB called before its own `put` line), so the object
* cannot come out right unless the splice happened AND the
* parent's source pointer resumed correctly afterward.
*
* `LIBGREET EXT` names a symbol this module does not define --
* exported by rellib.s (a second, separately-assembled REL
* module) -- proving cross-module REL linking, not just PUT.
*
* RESULT/EXITST are ordinary code-adjacent labels with SMALL
* module-relative addresses (this is a tiny module):
* decidemode's
* REL-aware ABS-forcing (docs/AS-PLASMA.md L1b, measured against
* merlin32 probe3/probe4 in the task report) is what keeps `STA
* RESULT`/`ADC RESULT` from wrongly picking zero-page mode here,
* the exact hazard those probes exist to catch.
*
* Exit status = LOCALCALL's return (5) + LIBGREET's return (10)
* =
* 15 ($0F) via the SAME SC_EXIT convention every maux userland
* program uses (src/liba/syscalls.s: A=status -> PROCPARM ->
* A/X=
* <PROCPARM/>PROCPARM, Y=SYS_EXIT, jsr $FF00) -- hand-rolled
* here
* (no liba `put`) to keep this fixture minimal and
* self-contained.
* `#<EXITST`/`#>EXITST` exercise the 1-byte internal fixup kinds
* ($0F low / $4F high); `JSR LOCALCALL`/`STA RESULT` exercise
* the
* 2-byte internal kind ($8F); `JSR LIBGREET` exercises the
* 2-byte
* external kind ($9F). See docs/REL-FORMAT.md.
*---------------------------------------------------------------
 REL
LIBGREET EXT
START LDA #0
 STA RESULT
 JSR LOCALCALL
 CLC
 ADC RESULT
 STA RESULT
 JSR LIBGREET
 CLC
 ADC RESULT
 STA EXITST
 LDA #<EXITST
 LDX #>EXITST
 LDY #$02
 JSR $FF00
:HANG JMP :HANG
RESULT DFB $00
EXITST DFB $00
 PUT relsub
* Expression regression bytes (not executed). The gate links at
* $0800 and $20F9 and compares EVERY byte with flat merlin32.
* Internal high selectors must retain the low-byte carry source;
* external high addends are page multiples (the $F8 constraint).
ZPCON EQU $20
FWDONE EQU FWDTWO+1
FWDTWO EQU FWDTHREE+1
FWDTAIL EQU FWDONE+3
FWDTHREE EQU $12
EXPR LDA RESULT+1
 LDA RESULT-1,X
 LDX RESULT+2,Y
 LDA ZPCON+1
 LDA ZPCON+2,X
 LDX ZPCON+3,Y
 LDA (ZPCON+4),Y
 LDA (ZPCON+5,X)
 LDA #<RESULT+255
 LDA #>RESULT+255
 LDA #<EXPR-1
 LDA #>EXPR+255
 LDA LIBGREET+1
 LDA LIBGREET-1,X
 LDA #<LIBGREET+255
 LDA #>LIBGREET+$100
 LDA #>LIBGREET-$100
 DFB <RESULT+255,>RESULT+255,"A",<LIBGREET+7
 DFB >LIBGREET+$100,'Z',>RESULT+256,<RESULT-1
 DA RESULT+3,LIBGREET+2,RESULT-1,LIBGREET-1
 DA RESULT-START,EXPR-RESULT,FWDONE,FWDTWO,FWDTAIL
 DA RESULT-START+EXPR
 DFB >RESULT-START,<EXPR-RESULT
 DA *,*+3
 DA *-2
 DFB 2+3*4,2+20/2,$80!$FF&$3F,$0F.$30
 DA $FFFF/2,$8000/256
 DUM $30
ABSBUF DS 2
 DEND
 LDA ABSBUF+1
 DUM *
RELBUF DS 2
 DEND
 LDA RELBUF+1
 DFB <RELBUF+255,>RELBUF+255
