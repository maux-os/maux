*---------------------------------------------------------------
* strtest.s -- acceptance gate for the 16-bit walk in
* src/liba/string.s (`make check-string`).
*
* WHY A DIRECT GATE AND NOT AN END-TO-END ONE. The caller audit
* of 2026-08-22 established that STRCMP's long-operand bug is
* reachable through `sort` and `diff` -- check-fleet's
* TWININ/TWINOUT covers that, and covers it the way it actually
* bites, as a line `sort -u` silently deletes. But two thirds of
* this file cannot be reached from any program in the tree at
* all:
*
*   STRCPY  every caller is fed from argv (sh caps a word at
*           LINEMAX=127) or from a reader with its own hard cap
*           (uniq and comm break their getline at 255). So no
*           program can hand STRCPY a 256-byte source, and a
*           gate that went looking for one would have to invent
*           a caller -- a fixture shaped to reach the bug is how
*           WIDEIN ended up 250 characters wide.
*   STRCMPI its one caller compares ProDOS directory names,
*           which cannot exceed 15 bytes.
*
* Unreachable is not the same as correct, and the whole lesson
* of the STRLEN widening is that caps get raised later from a
* different file. So these get a table run on the real 6502,
* the same shape globtest.s uses for GLOBMATCH.
*
* Each case writes 1 (pass) or 0 (fail) to RESULTS+n, and the
* case count to NCASES, where scripts/check_string.py peeks
* them. A case that never runs leaves $EE, which reads as
* neither.
*
* THE STRINGS ARE BUILT AT RUNTIME, not assembled. A 600-byte
* `asc` would not survive the 64-character source-line limit,
* and building them here means the fixture cannot silently
* disagree with itself about a length.
*
* THE VERIFIER IS INDEPENDENT. VFY walks with its own 16-bit
* page carry rather than calling STRCMP, because a gate that
* checks a routine with itself passes when the routine is
* uniformly wrong -- which is exactly the failure mode being
* tested here (the old walk called EVERYTHING past 255 equal).
*---------------------------------------------------------------

            lst   off
            xc
            org   $2000
            dsk   ../../build/MAUXSTR.SYSTEM
            typ   $FF

RESULTS     equ   $0300              ;one byte per case
NCASES      equ   $0340

* -- VFY's own walking pointers. This harness owns the machine
* -- (sei, no kernel, nothing runs after boot), so the classic
* -- free monitor scratch is genuinely free here.
VSRC        equ   $06
VDST        equ   $08

* -- Test buffers, page-aligned and far apart so an overrun
* -- lands in empty space rather than on another fixture
* -- (learning:01M07V2D0T25FYD6ASCMPJYNWQ: a test whose
* -- overflow case overflows its own fixtures cannot report).
BUFA        equ   $4000
BUFB        equ   $5000
BUFC        equ   $6000

START       sei
            ldx   #$FF
            txs
            cld

            ldx   #0                 ;pre-fill "did not run"
            lda   #$EE
:fill       sta   RESULTS,x
            inx
            cpx   #64
            bne   :fill
            stz   CASEI

            jsr   T_CMP
            jsr   T_CMPI
            jsr   T_CPY

            lda   CASEI
            sta   NCASES
SPIN        jmp   SPIN

*---------------------------------------------------------------
* STRCMP cases.
*---------------------------------------------------------------
T_CMP
*-- EVERY CASE SETS `WANT` BEFORE THE CALL UNDER TEST, never
*-- between the call and EXPECT. `lda #$FF / sta WANT` clobbers
*-- A, and A is where the routine's verdict lives -- so the
*-- between form makes EXPECT compare the expected value with
*-- itself and PASS UNCONDITIONALLY. This file shipped that on
*-- its first run: 21/21 green, and a sabotage that reverted
*-- STRCMP to the 8-bit walk was STILL 21/21. The battery was
*-- measuring nothing. Set WANT first; the fixtures do not
*-- touch it and neither does anything under test.

*-- 0: short, equal. SETAB is not optional either: SHORTAB
*-- leaves PTR0 on BUFB (it builds that one last), so a case
*-- that skips it compares BUFB against a stale PTR1 -- the
*-- other harness bug this battery shipped with.
            jsr   SHORTAB
            jsr   SETAB
            stz   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 1: short, A < B.
            jsr   SHORTAB
            lda   #$FF
            sta   PVAL
            lda   #1
            sta   POFF
            stz   POFF+1
            jsr   PTOB
            jsr   SETB
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 2: short, A > B.
            jsr   SHORTAB
            lda   #$FF
            sta   PVAL
            lda   #1
            sta   POFF
            stz   POFF+1
            jsr   PTOA
            jsr   SETB
            jsr   SETAB
            lda   #1
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 3: 300 bytes, GENUINELY equal. Without this a routine that
*-- simply never returned 0 would pass every case below.
            jsr   MK300
            jsr   SETAB
            stz   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 4: 300 bytes differing at byte 254 -- INSIDE the old 8-bit
*-- walk. THE CONTROL: this one passed before the widening too,
*-- so a run where it also goes red is a broken harness, not a
*-- broken routine.
            jsr   MK300
            lda   #254
            sta   POFF
            stz   POFF+1
            jsr   POKEHI
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 5: 300 bytes differing at byte 256, A < B. THE BUG: the old
*-- walk fell out at the 255->0 wrap into its own :eq and
*-- returned 0 for this.
            jsr   MK300
            stz   POFF
            lda   #1
            sta   POFF+1
            jsr   POKEHI
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 6: the same difference the other way round, A > B. Both
*-- signs, because a routine that returned a constant non-zero
*-- would pass case 5 alone.
            jsr   MK300
            stz   POFF
            lda   #1
            sta   POFF+1
            lda   #$FF
            sta   PVAL
            jsr   PTOA
            jsr   SETB
            jsr   SETAB
            lda   #1
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 7: 600 bytes differing at byte 512 -- TWO page carries in,
*-- so a walk that advanced the pointer once and stopped is
*-- caught here and nowhere else.
            jsr   MK600
            stz   POFF
            lda   #2
            sta   POFF+1
            jsr   POKEHI
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 8: A is a 300-byte PREFIX of a 400-byte B. No differing
*-- byte at all -- the strings part at A's terminator, past the
*-- wrap. The old walk reported these EQUAL as well.
            lda   #<300
            sta   MLEN
            lda   #>300
            sta   MLEN+1
            jsr   PTOA
            jsr   MKSTR
            lda   #<400
            sta   MLEN
            lda   #>400
            sta   MLEN+1
            jsr   PTOB
            jsr   MKSTR
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMP
            jsr   EXPECT

*-- 9: PTR0 and PTR1 both come back intact after a 600-byte
*-- compare. The 8-bit version never touched either, so every
*-- caller in the tree may already assume it -- sort.s reads
*-- PTR1 back as SRT_PREV.
            jsr   MK600
            jsr   SETAB
            jsr   SAVEPTRS
            jsr   STRCMP
            lda   #1
            sta   WANT
            jsr   PTRSKEPT
            jsr   EXPECT
            rts

*---------------------------------------------------------------
* STRCMPI cases. Same walk, plus the fold.
*---------------------------------------------------------------
T_CMPI
*-- 10: 300 bytes differing ONLY in case, all the way through.
*-- Must fold to equal.
            jsr   MKALPHAB
            jsr   SETAB
            stz   WANT
            jsr   STRCMPI
            jsr   EXPECT

*-- 11: the same pair with a REAL difference at byte 256 -- one
*-- that survives folding. 'U' ($D5) against a folded 'a'
*-- ($E1 -> $C1), so A < B.
            jsr   MKALPHAB
            stz   POFF
            lda   #1
            sta   POFF+1
            lda   #$D5
            sta   PVAL
            jsr   PTOB
            jsr   SETB
            jsr   SETAB
            lda   #$FF
            sta   WANT
            jsr   STRCMPI
            jsr   EXPECT

*-- 12: pointers restored, same contract as STRCMP.
            jsr   MKALPHAB
            jsr   SETAB
            jsr   SAVEPTRS
            jsr   STRCMPI
            lda   #1
            sta   WANT
            jsr   PTRSKEPT
            jsr   EXPECT
            rts

*---------------------------------------------------------------
* STRCPY cases. The 8-bit version stopped at the wrap having
* written 256 bytes and NO TERMINATOR, then returned 0.
*---------------------------------------------------------------
T_CPY
*-- 13/14/15: one 300-byte copy, checked three ways -- the
*-- bytes arrived, and the length came back as A = low / X =
*-- high. 300 = $012C, so A = $2C and X = $01. A caller storing
*-- A alone in a byte gets 44 and must test X first; that is
*-- what find.s and du.s now do before `sta PATHLEN`.
            jsr   MK300CPY
            lda   #1
            sta   WANT
            jsr   VFYCPY
            jsr   EXPECT
            lda   #$2C
            sta   WANT
            lda   CPYLEN
            jsr   EXPECT
            lda   #1
            sta   WANT
            lda   CPYLEN+1
            jsr   EXPECT

*-- 16/17/18: 600 bytes -- two page carries. 600 = $0258. The
*-- tail case checks the byte one PAST the copied terminator is
*-- still the paint sentinel, so a copy that runs long is
*-- caught as well as one that stops short.
            jsr   MK600CPY
            lda   #1
            sta   WANT
            jsr   VFYCPY
            jsr   EXPECT
            lda   #$58
            sta   WANT
            lda   CPYLEN
            jsr   EXPECT
            lda   #2
            sta   WANT
            lda   CPYLEN+1
            jsr   EXPECT
            lda   #1
            sta   WANT
            jsr   TAILKEPT
            jsr   EXPECT

*-- 19: pointers restored after a 600-byte copy. Needs its own
*-- copy: VFYCPY above repoints PTR0/PTR1, so it has to run
*-- before anything else touches them.
            jsr   MK600CPY
            lda   #1
            sta   WANT
            jsr   PTRSKEPT
            jsr   EXPECT
            rts

*---------------------------------------------------------------
* Case plumbing.
*---------------------------------------------------------------

* REC -- record A (1 pass / 0 fail) as the next case's result.
REC         ldx   CASEI
            sta   RESULTS,x
            inc   CASEI
            rts

* EXPECT -- IN: A = actual, WANT = expected. Tail-calls REC.
EXPECT      cmp   WANT
            beq   :ok
            lda   #0
            bra   REC
:ok         lda   #1
            bra   REC

* PTOA / PTOB / PTOC -- point PTR0 at a buffer.
PTOA        lda   #<BUFA
            sta   PTR0
            lda   #>BUFA
            sta   PTR0+1
            rts
PTOB        lda   #<BUFB
            sta   PTR0
            lda   #>BUFB
            sta   PTR0+1
            rts
PTOC        lda   #<BUFC
            sta   PTR0
            lda   #>BUFC
            sta   PTR0+1
            rts

* SETAB -- PTR0 = BUFA, PTR1 = BUFB, ready for a compare.
SETAB       jsr   PTOA
            lda   #<BUFB
            sta   PTR1
            lda   #>BUFB
            sta   PTR1+1
            rts

* SAVEPTRS / PTRSKEPT -- stash PTR0/PTR1 and check them back.
* A = 1 if all four bytes survived.
SAVEPTRS    lda   PTR0
            sta   SV0
            lda   PTR0+1
            sta   SV0+1
            lda   PTR1
            sta   SV1
            lda   PTR1+1
            sta   SV1+1
            rts
PTRSKEPT    lda   PTR0
            cmp   SV0
            bne   :no
            lda   PTR0+1
            cmp   SV0+1
            bne   :no
            lda   PTR1
            cmp   SV1
            bne   :no
            lda   PTR1+1
            cmp   SV1+1
            bne   :no
            lda   #1
            rts
:no         lda   #0
            rts

*---------------------------------------------------------------
* Fixture builders.
*---------------------------------------------------------------

* MKSTR -- write MLEN pattern bytes plus a NUL at PTR0. The
* pattern is a function of the low index only ($A0 + (Y & $1F),
* never zero), so two strings of equal length built this way
* are byte-identical and a poked byte is the ONLY difference.
MKSTR       lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            lda   MLEN
            sta   MCNT
            lda   MLEN+1
            sta   MCNT+1
            ldy   #0
:loop       lda   MCNT
            ora   MCNT+1
            beq   :term
            tya
            and   #$1F
            ora   #$A0
            sta   (PTR2),y
            iny
            bne   :nopg
            inc   PTR2+1
:nopg       lda   MCNT
            bne   :dec
            dec   MCNT+1
:dec        dec   MCNT
            bra   :loop
:term       lda   #0
            sta   (PTR2),y
            rts

* MKALPHA -- MKSTR in letters instead: ABASE + (Y & $0F), so
* $C1..$D0 for upper and $E1..$F0 for lower. SIFOLD maps the
* lower run onto the upper one exactly.
MKALPHA     lda   PTR0
            sta   PTR2
            lda   PTR0+1
            sta   PTR2+1
            lda   MLEN
            sta   MCNT
            lda   MLEN+1
            sta   MCNT+1
            ldy   #0
:loop       lda   MCNT
            ora   MCNT+1
            beq   :term
            tya
            and   #$0F
            clc
            adc   ABASE
            sta   (PTR2),y
            iny
            bne   :nopg
            inc   PTR2+1
:nopg       lda   MCNT
            bne   :dec
            dec   MCNT+1
:dec        dec   MCNT
            bra   :loop
:term       lda   #0
            sta   (PTR2),y
            rts

* SETB -- store PVAL at PTR0 + POFF (16-bit offset).
SETB        lda   PTR0
            clc
            adc   POFF
            sta   PTR2
            lda   PTR0+1
            adc   POFF+1
            sta   PTR2+1
            ldy   #0
            lda   PVAL
            sta   (PTR2),y
            rts

* POKEHI -- the usual "make B greater at POFF": $FF beats every
* byte MKSTR emits.
POKEHI      lda   #$FF
            sta   PVAL
            jsr   PTOB
            jmp   SETB

* SHORTAB -- three-byte equal strings in both buffers.
SHORTAB     lda   #3
            sta   MLEN
            stz   MLEN+1
            jsr   PTOA
            jsr   MKSTR
            jsr   PTOB
            jmp   MKSTR

* MK300 / MK600 -- equal-length pattern strings in both.
MK300       lda   #<300
            sta   MLEN
            lda   #>300
            sta   MLEN+1
            bra   MKBOTH
MK600       lda   #<600
            sta   MLEN
            lda   #>600
            sta   MLEN+1
MKBOTH      jsr   PTOA
            jsr   MKSTR
            jsr   PTOB
            jmp   MKSTR

* MKALPHAB -- BUFA lowercase, BUFB uppercase, 300 bytes each.
MKALPHAB    lda   #<300
            sta   MLEN
            lda   #>300
            sta   MLEN+1
            lda   #$E1
            sta   ABASE
            jsr   PTOA
            jsr   MKALPHA
            lda   #$C1
            sta   ABASE
            jsr   PTOB
            jmp   MKALPHA

*---------------------------------------------------------------
* The copy fixtures. PAINT fills the destination with a
* sentinel first so a short copy and a long one look different:
* $5A is not a pattern byte, not a terminator, and not $EE.
*---------------------------------------------------------------
MK300CPY    lda   #<300
            sta   MLEN
            lda   #>300
            sta   MLEN+1
            bra   DOCPY
MK600CPY    lda   #<600
            sta   MLEN
            lda   #>600
            sta   MLEN+1
DOCPY       jsr   PTOA
            jsr   MKSTR
            jsr   PAINTC
            jsr   PTOA
            lda   #<BUFC
            sta   PTR1
            lda   #>BUFC
            sta   PTR1+1
            jsr   SAVEPTRS
            jsr   STRCPY
            sta   CPYLEN
            stx   CPYLEN+1
            rts

* PAINTC -- $5A over MLEN+16 bytes of BUFC, so the tail check
* has untouched ground to stand on.
PAINTC      lda   #<BUFC
            sta   PTR2
            lda   #>BUFC
            sta   PTR2+1
            lda   MLEN
            sta   MCNT
            lda   MLEN+1
            sta   MCNT+1
            clc
            lda   MCNT
            adc   #16
            sta   MCNT
            bcc   :go
            inc   MCNT+1
:go         ldy   #0
:loop       lda   MCNT
            ora   MCNT+1
            beq   :done
            lda   #$5A
            sta   (PTR2),y
            iny
            bne   :nopg
            inc   PTR2+1
:nopg       lda   MCNT
            bne   :dec
            dec   MCNT+1
:dec        dec   MCNT
            bra   :loop
:done       rts

* VFYCPY -- BUFC must equal BUFA for MLEN+1 bytes (terminator
* included). A = 1 if so.
VFYCPY      jsr   PTOA
            lda   #<BUFC
            sta   PTR1
            lda   #>BUFC
            sta   PTR1+1
            jmp   VFY

* TAILKEPT -- the byte just past the copied terminator must
* still be the $5A sentinel. Catches a copy that ran long.
TAILKEPT    lda   #<BUFC
            clc
            adc   MLEN
            sta   PTR2
            lda   #>BUFC
            adc   MLEN+1
            sta   PTR2+1
            ldy   #1
            lda   (PTR2),y
            cmp   #$5A
            beq   :ok
            lda   #0
            rts
:ok         lda   #1
            rts

* VFY -- compare MLEN+1 bytes at PTR0 against PTR1, walking
* 16-bit with its OWN page carry. Deliberately not built on the
* routines under test: a self-checking gate passes when the
* routine is uniformly wrong, which is this bug exactly.
VFY         lda   PTR0
            sta   VSRC
            lda   PTR0+1
            sta   VSRC+1
            lda   PTR1
            sta   VDST
            lda   PTR1+1
            sta   VDST+1
            lda   MLEN
            sta   MCNT
            lda   MLEN+1
            sta   MCNT+1
            inc   MCNT             ;+1 for the terminator
            bne   :go
            inc   MCNT+1
:go         ldy   #0
:loop       lda   MCNT
            ora   MCNT+1
            beq   :same
            lda   (VSRC),y
            cmp   (VDST),y
            bne   :diff
            iny
            bne   :nopg
            inc   VSRC+1
            inc   VDST+1
:nopg       lda   MCNT
            bne   :dec
            dec   MCNT+1
:dec        dec   MCNT
            bra   :loop
:diff       lda   #0
            rts
:same       lda   #1
            rts

*---------------------------------------------------------------
* Harness storage. Real bytes, not a `dum` arena -- this file
* is a boot-and-spin test image, not a maux process, so there
* is no LIBA_BSSEND to anchor to and nothing spawns it twice.
*---------------------------------------------------------------
CASEI       ds    1
WANT        ds    1
ABASE       ds    1
PVAL        ds    1
MLEN        ds    2
MCNT        ds    2
POFF        ds    2
SV0         ds    2
SV1         ds    2
CPYLEN      ds    2

            put   ../../inc/zp.equ
            put   ../liba/string.s
* -- string.s's SCI_B lives in liba's shared `dum` arena
* -- (docs/STICKY.md sec 25), so this manifest carries the
* -- arena too -- and it must stay the LAST `put`, with nothing
* -- emitted after it (scripts/check_purity.py checks).
            put   ../liba/libabss.s
