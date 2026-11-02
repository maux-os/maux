*---------------------------------------------------------------
* glob.s -- filename pattern matching for the shell.
*
* GLOBMATCH: PTR0 = pattern, PTR1 = name, both high-bit-set and
* NUL-terminated. Carry CLEAR on match.
*
* Supports the Bourne set: `*` any run including empty, `?` any
* single character, `[abc]` / `[a-z]` / `[!abc]` classes.
*
* CASE-INSENSITIVE, and that is not a style choice. ProDOS
* matches names case-insensitively and stores them uppercase
* with the mixed case carried in separate bitflags
* (docs/PRODOS-VERSION.md). A case-SENSITIVE glob would let `ls`
* display `Notes.txt` while `rm *.txt` silently missed it. Both
* sides are folded to upper before comparing.
*
* Backtracking is iterative, not recursive: on a mismatch after
* a `*`, rewind to the character after that `*` and retry with
* the star having eaten one more character. Recursion would put
* an unbounded pattern-dependent depth on a stack that also
* carries the syscall path.
*
* Indices, not pointers: pattern and name are both under 256
* bytes, so the four cursors are plain bytes and the whole
* routine needs no zero page beyond the PTR0/PTR1 it is handed.
*---------------------------------------------------------------

GLOBMATCH   stz   GPI                ;pattern cursor
            stz   GNI                ;name cursor
            lda   #$FF
            sta   GSPI               ;$FF = no `*` seen yet
            sta   GSNI

:loop       ldy   GNI
            lda   (PTR1),y
            beq   :nameend           ;name exhausted

            ldy   GPI
            lda   (PTR0),y
            beq   :backtrack         ;pattern ran out, name did
                                     ;not
            cmp   #$AA               ;'*' high-bit-set
            beq   :star
            cmp   #$BF               ;'?' -- matches any one
            beq   :advance
            cmp   #$DB               ;'[' -- character class
            beq   :class
            jsr   GFOLD
            sta   GTMP
            ldy   GNI
            lda   (PTR1),y
            jsr   GFOLD
            cmp   GTMP
            beq   :advance
            bra   :backtrack

:advance    inc   GPI
            inc   GNI
            bra   :loop

:star       inc   GPI                ;remember where to resume,
            lda   GPI                ;and how much the star has
            sta   GSPI               ;eaten so far
            lda   GNI
            sta   GSNI
            bra   :loop

:backtrack  lda   GSPI
            cmp   #$FF
            beq   :nomatch           ;no star to stretch
            inc   GSNI               ;let it eat one more
            lda   GSNI
            sta   GNI
            lda   GSPI               ;GNI may now sit ON the
            sta   GPI                ;terminator, which is legal
            bra   :loop              ;-- `*` eating the whole
                                     ;name. :nameend decides,
                                     ;and always terminates, so
                                     ;no guard belongs here.

* Name is exhausted: any trailing `*`s may match empty, but
* nothing else can.
:nameend    ldy   GPI
            lda   (PTR0),y
            beq   :match
            cmp   #$AA               ;'*'
            bne   :nomatch
            inc   GPI
            bra   :nameend

:match      clc
            rts
:nomatch    sec
            rts

*---------------------------------------------------------------
* `[abc]`, `[a-z]`, `[!abc]`. An unterminated class fails the
* match rather than being treated as a literal `[`.
*---------------------------------------------------------------
:class      inc   GPI                ;step past '['
            stz   GNEG
            ldy   GPI
            lda   (PTR0),y
            cmp   #$A1               ;'!' high-bit-set
            bne   :cfirst
            lda   #1
            sta   GNEG
            inc   GPI
:cfirst     stz   GHIT
            ldy   GNI
            lda   (PTR1),y
            jsr   GFOLD
            sta   GCH
:cscan      ldy   GPI
            lda   (PTR0),y
            beq   :cnomat            ;unterminated class
            cmp   #$DD               ;']' ends the class
            beq   :cdone
            jsr   GFOLD
            sta   GLO
            inc   GPI
            ldy   GPI
            lda   (PTR0),y
            cmp   #$AD               ;'-' -> a range
            bne   :csingle
            iny
            lda   (PTR0),y
            cmp   #$DD               ;"a-]" : the '-' is literal
            beq   :csingle
            inc   GPI
            ldy   GPI
            lda   (PTR0),y
            jsr   GFOLD
            sta   GHI
            inc   GPI
            lda   GCH
            cmp   GLO
            bcc   :cscan
            lda   GHI
            cmp   GCH
            bcc   :cscan
            lda   #1
            sta   GHIT
            bra   :cscan
:csingle    lda   GCH
            cmp   GLO
            bne   :cscan
            lda   #1
            sta   GHIT
            bra   :cscan

:cdone      inc   GPI                ;step past ']'
            lda   GNEG
            beq   :cplain
            lda   GHIT               ;negated: hit = NO match
            bne   :cback
            bra   :cadv
:cplain     lda   GHIT
            beq   :cback
:cadv       inc   GNI                ;GPI is already past ']',
            jmp   :loop              ;so only the name advances

* The class block sits too far from the main loop's exits for
* relative branches, so it reaches them through these.
:cback      jmp   :backtrack
:cnomat     sec
            rts

*---------------------------------------------------------------
* GFOLD -- A = ASCII, returned folded to upper case, high bit
* SET. Only $E1-$FA ('a'-'z') move in case; digits, '.', and
* everything else keep their value.
*
* THE `ora` NORMALISES BIT 7 and is why a caller may hand this
* routine either convention. src/bin/sh.s marks a backslash-
* escaped byte by CLEARING bit 7 (docs/SHELL-GAPS.md sec 3b), so
* a pattern reaching GLOBMATCH can hold `A` as $41 while the
* directory name holds it as $C1. Those must compare EQUAL --
* the escape said "this character is literal", not "this
* character is different". The metacharacter tests in GLOBMATCH
* all run BEFORE this call and all compare against high-bit
* constants, which is exactly what makes a cleared `*` stop
* being a wildcard while a cleared `A` keeps being an A.
*
* No existing caller is affected: every other pattern in the
* tree is already high-bit, and `ora #$80` on a high-bit byte
* changes nothing.
*---------------------------------------------------------------
GFOLD       ora   #$80
            cmp   #$E1
            bcc   :done
            cmp   #$FB
            bcs   :done
            sec
            sbc   #$20
:done       rts

*---------------------------------------------------------------
* HASMETA -- carry CLEAR if the NUL-terminated high-bit string
* at PTR0 contains a glob metacharacter. Lets sh skip the whole
* directory walk for ordinary words.
*---------------------------------------------------------------
HASMETA     ldy   #0
:lp         lda   (PTR0),y
            beq   :plain
            cmp   #$AA               ;'*'
            beq   :meta
            cmp   #$BF               ;'?'
            beq   :meta
            cmp   #$DB               ;'['
            beq   :meta
            iny
            bne   :lp
:plain      sec
            rts
:meta       clc
            rts

* -- The ten cursor/scratch bytes this matcher runs on used to
* -- be declared here as emitted `ds` text that GLOBMATCH then
* -- wrote -- writable text, which docs/STICKY.md sec 21
* -- forbids. They are in src/liba/libabss.s's `dum` arena now
* -- (sec 25): all ten are per-call scratch, written before they
* -- are read, so uncleared memory is safe for them and the
* -- trace is recorded beside the declarations.
