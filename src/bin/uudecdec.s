*---------------------------------------------------------------
* uudecdec.s -- uudecode's character-level decode primitives:
* the two alphabets (DECODE6/B64DEC), the 4-char-to-3-byte
* reconstructor (RECON4), and the header-line scanner
* (PREFIXCMP/PARSEHDR). `put` by src/bin/uudecode.s (NOT a
* standalone binary -- the same put-module shape as printf.s/
* printffmt.s and cut.s/cutlist.s): uudecode's own resident text
* plus its whole decode engine ran past the native assembler's
* 16128-byte window in one piece, and `as` holds exactly one put
* file's text at a time (docs/S9-PLAN.md sec 5), so the engine
* is split in two -- this file and src/bin/uudecln.s (the two
* per-line drivers and the line reader) -- each well under any
* existing liba put's own size, so neither becomes the new
* "largest put" the budget is measured against. Every symbol
* here resolves against uudecode.s's own zero page, equates and
* `dum` cells -- see that file's own header for the algorithm.
*---------------------------------------------------------------
*---------------------------------------------------------------
* PREFIXCMP -- IN: PTR0 = haystack, PTR1 = NUL-terminated
* needle. OUT: carry CLEAR if haystack starts with needle.
* CLOBBERS: A, Y.
*---------------------------------------------------------------
PREFIXCMP   ldy   #0
:pclp       lda   (PTR1),y
            beq   :pcyes
            cmp   (PTR0),y
            bne   :pcno
            iny
            bra   :pclp
:pcyes      clc
            rts
:pcno       sec
            rts

*---------------------------------------------------------------
* PARSEHDR -- IN: A = HSKIP (bytes of the literal "begin[-
* base64] " prefix already matched). Skips the MODE digits and
* one following space, then copies the rest of LINEBUF into
* HDRNAME (NUL-terminated, capped at HNCAP characters).
* CLOBBERS: A, X, Y, PH_I.
*---------------------------------------------------------------
PARSEHDR    sta   PH_I
:phdig      ldx   PH_I
            cpx   LINELEN
            bcs   :phcopy
            lda   LINEBUF,x
            cmp   #'0'
            bcc   :phsp
            cmp   #'9'+1
            bcs   :phsp
            inc   PH_I
            bra   :phdig
:phsp       ldx   PH_I
            cpx   LINELEN
            bcs   :phcopy
            lda   LINEBUF,x
            cmp   #$20
            bne   :phcopy
            inc   PH_I
:phcopy     ldy   #0
:phcplp     ldx   PH_I
            cpx   LINELEN
            bcs   :phcpend
            cpy   #HNCAP
            bcs   :phcpend
            lda   LINEBUF,x
            sta   HDRNAME,y
            inc   PH_I
            iny
            bra   :phcplp
:phcpend    lda   #0
            sta   HDRNAME,y
            rts

*---------------------------------------------------------------
* DECODE6 -- historical alphabet. IN: A = a normalized (7-bit)
* character. OUT: carry CLEAR + A = 0-63 if it is a valid
* uuencode character ($20-$60 inclusive, backquote and space
* both decoding to 0); carry SET otherwise. CLOBBERS: A.
*---------------------------------------------------------------
DECODE6     cmp   #$20
            bcc   :d6bad
            cmp   #$61
            bcs   :d6bad
            sec
            sbc   #$20
            and   #$3F
            clc
            rts
:d6bad      sec
            rts

*---------------------------------------------------------------
* B64DEC -- RFC 4648 alphabet. IN: A = a normalized character.
* OUT: carry CLEAR + A = 0-63 for a data character; carry SET +
* A = 0 for '=' (padding); carry SET + A = $FF for anything
* else. CLOBBERS: A.
*---------------------------------------------------------------
* -- Checked in ASCENDING ASCII order (a real bug, found live:
* -- checking 'A'-'Z' before '0'-'9' put `cmp #'A'/bcc :bdinv`
* -- first, and every digit is BELOW 'A' -- so '0'-'9' took the
* -- invalid exit before the digit check was ever reached).
* -- '=' and the two punctuation chars are exact matches, tried
* -- before the range cascade so they cannot collide with it.
B64DEC      cmp   #'='
            bne   :bdc1
            lda   #0
            sec
            rts
:bdc1       cmp   #'+'
            bne   :bdc2
            lda   #62
            clc
            rts
:bdc2       cmp   #'/'
            bne   :bdc3
            lda   #63
            clc
            rts
:bdc3       cmp   #'0'
            bcc   :bdinv
            cmp   #'9'+1
            bcs   :bdc4
            sec
            sbc   #'0'
            clc
            adc   #52
            rts
:bdc4       cmp   #'A'
            bcc   :bdinv
            cmp   #'Z'+1
            bcs   :bdc5
            sec
            sbc   #'A'
            clc
            rts
:bdc5       cmp   #'a'
            bcc   :bdinv
            cmp   #'z'+1
            bcs   :bdinv
            sec
            sbc   #'a'
            clc
            adc   #26
            rts
:bdinv      lda   #$FF
            sec
            rts

*---------------------------------------------------------------
* RECON4 -- IN: A = 1-3 (how many of the 3 reconstructed bytes
* are real), DU_V0-3 = four 6-bit groups. Rebuilds DU_BYTE0-2
* and PUTCs the first A of them to OUTFD. CLOBBERS: A, X,
* DU_CNT, DU_TMP, DU_BYTE0-2.
*---------------------------------------------------------------
RECON4      sta   DU_CNT
            lda   DU_V0
            asl   a
            asl   a
            sta   DU_TMP
            lda   DU_V1
            lsr   a
            lsr   a
            lsr   a
            lsr   a
            ora   DU_TMP
            sta   DU_BYTE0
            lda   DU_V1
            and   #$0F
            asl   a
            asl   a
            asl   a
            asl   a
            sta   DU_TMP
            lda   DU_V2
            lsr   a
            lsr   a
            ora   DU_TMP
            sta   DU_BYTE1
            lda   DU_V2
            and   #3
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            asl   a
            sta   DU_TMP
            lda   DU_V3
            ora   DU_TMP
            sta   DU_BYTE2
            lda   DU_BYTE0
            ldx   OUTFD
            jsr   PUTC
            lda   DU_CNT
            cmp   #2
            bcc   :rc4done
            lda   DU_BYTE1
            ldx   OUTFD
            jsr   PUTC
            lda   DU_CNT
            cmp   #3
            bcc   :rc4done
            lda   DU_BYTE2
            ldx   OUTFD
            jsr   PUTC
:rc4done    rts
