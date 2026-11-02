* boundary.s -- focused NAS refactor regression fixture.
*
* Existing stress.s covers the mode table broadly. This fixture
* keeps the
* high-value boundary decisions observable in a small byte
* oracle:
*   - $00FE/$00FF/$0100 page boundaries (forward-small replay is
*   in
*     forward.s, whose semantics intentionally use a frozen NAS
*     oracle);
*   - XC-only (zp), (abs,X), and BRA;
*   - exact +127/-128 branches;
*   - left-to-right folds, selectors, quoted chars, and current
*   PC.
* Existing stress.s covers forward EQU chains; noxc.s checks XC
* reset.
*
* merlin32 is the independent oracle. No expected bytes are
* encoded here.
*---------------------------------------------------------------
        xc
        org   $2000

ZPVAL   equ   $00FE
ZPLAST  equ   $00FF
PAGE    equ   $0100

START   lda   ZPVAL          ;resolved zero-page
        lda   ZPLAST         ;last byte of zero-page
        lda   PAGE           ;first byte of page two
        lda   (ZPVAL) ;65C02 (zp), not an indirect fallback
        sta   (ZPVAL)
        jmp   (TARGET,x)     ;65C02 (abs,X)
        bra   PLUS127        ;exact positive branch limit
        ds    127
PLUS127 nop

NEGBASE nop                  ;target is exactly 128 bytes back
        ds    125
        bcc   NEGBASE

        lda   #10-3-2        ;strict left-to-right = 5
        lda   #20/2/5         ;strict left-to-right = 2
        lda   #<TARGET+255
        lda   #>TARGET+255
        lda   #'A'+1
        lda   #"A"+1
        lda   #$FFFF/2
        lda   #$8000/256
        dfb   <TARGET+1,>TARGET+1
        da    *,*+3

TARGET  nop
        rts
