*---------------------------------------------------------------
* timeoutsig.s -- timeout's SIGNAL-name parsing (TO_PARSESIG,
* TO_NAMEIS), split out of timeoutparse.s 2026-09-21 for the
* vendored `as`'s 16,128-byte source window: the budget is the
* manifest plus its LARGEST single put, and timeout.s's 9,268
* against timeoutparse.s's 7,573 was 16,841. A unit over that
* window cannot be rebuilt by maux itself.
*
* Split HERE because it is the file's one clean seam -- duration
* parsing above, signal naming below, nothing shared but the
* TO_* scratch cells timeout.s declares. `put` by timeout.s at
* top level; Merlin cannot nest a put inside a put file.
*---------------------------------------------------------------
*---------------------------------------------------------------
* TO_PARSESIG -- IN: PTR0 = operand text (-s's argument). OUT:
* carry CLEAR, TO_SIGNO = the value; carry SET = neither a
* decimal number 0-255 nor one of TERM/KILL/HUP/INT/QUIT
* (case-insensitive). Numeric parse is kill.s's own PARSEPID,
* renamed; the name table is shtrap.s's TRAP_AS_SIG mechanism,
* NOT kill.s's (kill.s parses numbers only) -- see this file's
* header. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
TO_PARSESIG ldy   #0
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :byname
            cmp   #'9'+1
            bcs   :byname
            stz   TO_SIGNO
:numlp      lda   (PTR0),y
            beq   :numok
            and   #$7F
            cmp   #'0'
            bcc   :bad
            cmp   #'9'+1
            bcs   :bad
            sec
            sbc   #'0'
            pha
            lda   TO_SIGNO
            asl   a
            bcs   :badp
            asl   a
            bcs   :badp
            adc   TO_SIGNO
            bcs   :badp
            asl   a
            bcs   :badp
            sta   TO_SIGNO
            pla
            clc
            adc   TO_SIGNO
            bcs   :bad
            sta   TO_SIGNO
            iny
            bra   :numlp
:badp       pla
:bad        sec
            rts
:numok      clc
            rts
:byname     lda   #15
            sta   TO_SIGNO
            lda   #<SIGNM_TERM
            ldx   #>SIGNM_TERM
            jsr   TO_NAMEIS
            bcs   :numok
            lda   #9
            sta   TO_SIGNO
            lda   #<SIGNM_KILL
            ldx   #>SIGNM_KILL
            jsr   TO_NAMEIS
            bcs   :numok
            lda   #1
            sta   TO_SIGNO
            lda   #<SIGNM_HUP
            ldx   #>SIGNM_HUP
            jsr   TO_NAMEIS
            bcs   :numok
            lda   #2
            sta   TO_SIGNO
            lda   #<SIGNM_INT
            ldx   #>SIGNM_INT
            jsr   TO_NAMEIS
            bcs   :numok
            lda   #3
            sta   TO_SIGNO
            lda   #<SIGNM_QUIT
            ldx   #>SIGNM_QUIT
            jsr   TO_NAMEIS
            bcs   :numok
            bra   :bad

*-- TO_NAMEIS -- A/X = a name. Carry SET iff PTR0's operand
*-- equals it (case-insensitive). Preserves PTR0.
TO_NAMEIS   sta   PTR1
            stx   PTR1+1
            lda   PTR0
            pha
            lda   PTR0+1
            pha
            jsr   STRCMPI
            sta   TO_NMTMP
            pla
            sta   PTR0+1
            pla
            sta   PTR0
            lda   TO_NMTMP
            bne   :ne
            sec
            rts
:ne         clc
            rts
