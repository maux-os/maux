*---------------------------------------------------------------
* tresc.s -- tr's input-set PRE-PASS: backslash escapes and
* [:class:] expansion, split out of trbody.s 2026-09-21 for the
* vendored `as`'s 16,128-byte source window (manifest plus the
* largest single put). trbody.s had reached 15,281 stripped
* against a 2,132-byte manifest, i.e. 17,413, and a unit over
* that window cannot be rebuilt by maux itself.
*
* `put` by tr.s at top level, not by trbody.s -- Merlin cannot
* nest a put inside a put file.
*---------------------------------------------------------------
*---------------------------------------------------------------
* ESCPASS -- decode backslash escapes in the string at PTR0 into
* ESCBUF, then point PTR0 at ESCBUF. A separate PASS rather than
* a case inside EXPAND: EXPAND's range logic looks one and two
* bytes ahead of the current character to spot `c1-c2`, and an
* escape makes "the next character" a variable number of bytes
* away. Decoding first leaves EXPAND reading plain bytes and
* needing no change at all.
*
* THE NEWLINE IS A CARRIAGE RETURN ON THIS MACHINE, so `\n` and
* `\r` both produce $8D. That is not a fudge: $8D is the byte a
* maux text file actually carries at end of line, so `tr '\n' _`
* replaces the line endings a person can see, which is the whole
* reason anyone types it.
*
* `\ooo` is taken as a CHARACTER value and given the high bit,
* because every other byte in this pipeline has it: argv arrives
* high-bit ASCII and so does the file. `\101` therefore matches
* the 'A' in a maux file ($C1), not $41, which nothing would
* ever match.
*
* KNOWN CORNER, stated rather than hidden: `\-` decodes to a
* plain '-' here, so `a\-z` reaches EXPAND as `a-z` and expands
* as a RANGE where POSIX wants the three literal characters. A
* faithful `\-` needs the escape state carried INTO EXPAND's
* range test, which is the restructure this pass exists to
* avoid. Rare enough to name and leave.
*---------------------------------------------------------------
ESCPASS     stz   ESCSRC
            stz   ESCDST
:eloop      ldy   ESCSRC
            lda   (PTR0),y
            bne   :emore
            jmp   :edone                ;out of bra range
:emore      cmp   #$DC                  ;'\'
            beq   :esc
            cmp   #$DB                  ;'['
            bne   :eplain
            ldy   ESCSRC
            iny
            lda   (PTR0),y
            cmp   #$BA                  ;'[:' opens a class
            bne   :eplain
            jsr   ESCCLASS
            jmp   :eloop
:eplain     ldy   ESCDST
            sta   ESCBUF,y
            inc   ESCDST
            inc   ESCSRC
            jmp   :eloop
:esc        inc   ESCSRC                ;past the backslash
            ldy   ESCSRC
            lda   (PTR0),y
            bne   :ehave
            lda   #$DC                  ;trailing '\': literal
            bra   :eplain
:ehave      cmp   #$B0                  ;'0'
            bcc   :enamed
            cmp   #$B8                  ;past '7'
            bcs   :enamed
*-- octal: up to three digits, value | $80 (see the header)
            lda   #0
            sta   ESCVAL
            ldx   #3
:eoct       ldy   ESCSRC
            lda   (PTR0),y
            cmp   #$B0
            bcc   :eoctend
            cmp   #$B8
            bcs   :eoctend
            and   #$07
            sta   ESCTMP
            lda   ESCVAL
            asl   a
            asl   a
            asl   a
            ora   ESCTMP
            sta   ESCVAL
            inc   ESCSRC
            dex
            bne   :eoct
:eoctend    lda   ESCVAL
            ora   #$80
            ldy   ESCDST
            sta   ESCBUF,y
            inc   ESCDST
            jmp   :eloop                ;out of bra range
:enamed     ldx   #0
:elook      lda   ESCNAME,x
            beq   :eself                ;not a named escape
            ldy   ESCSRC
            cmp   (PTR0),y
            beq   :efound
            inx
            bra   :elook
:efound     lda   ESCCODE,x
            ldy   ESCDST
            sta   ESCBUF,y
            inc   ESCDST
            inc   ESCSRC
            jmp   :eloop
*-- an unknown escape is the character itself, which is what a
*-- live BSD tr does where POSIX leaves it undefined.
:eself      ldy   ESCSRC
            lda   (PTR0),y
            ldy   ESCDST
            sta   ESCBUF,y
            inc   ESCDST
            inc   ESCSRC
            jmp   :eloop
:edone      ldy   ESCDST
            lda   #0
            sta   ESCBUF,y
            lda   #<ESCBUF
            sta   PTR0
            lda   #>ESCBUF
            sta   PTR0+1
            rts

ESCNAME     dfb   $DC,$EE,$F2,$F4,$E1,$E2,$E6,$F6,$00
ESCCODE     dfb   $DC,$8D,$8D,$89,$87,$88,$8C,$8B

*---------------------------------------------------------------
* ESCCLASS -- expand `[:name:]` at ESCSRC into the characters of
* that class, in the same pass and the same buffer the escapes
* use. A class IS a set of characters, so emitting its members
* leaves EXPAND with the plain bytes it already understands --
* the same reason the escapes are decoded here rather than
* inside EXPAND.
*
* THE RANGES ARE THIS MACHINE'S, not ASCII's. Every byte in this
* pipeline is high-bit ASCII, so [:digit:] is $B0-$B9 and not
* $30-$39, and [:space:] carries $8D ONCE where a host lists
* newline and carriage return separately -- on this machine they
* are the same byte. EXEMIT already de-duplicates membership, so
* a class that overlaps another costs nothing.
*
* An unknown class name is left alone -- the '[' is emitted as
* an ordinary character and the scan resumes after it, which is
* what a set containing a literal '[' needs.
*---------------------------------------------------------------
ESCCLASS    lda   ESCSRC
            clc
            adc   #2                    ;past "[:"
            sta   ESCNPOS
            lda   #<CLSTAB
            sta   PTR2
            lda   #>CLSTAB
            sta   PTR2+1
:crec       ldy   #0
            lda   (PTR2),y
            bne   :chave
            jmp   :cnone                ;end of table
:chave
            sta   CLSLEN
            ldx   #0
:cmatch     ldy   ESCNPOS
            phy
            txa
            clc
            adc   ESCNPOS
            tay
            lda   (PTR0),y
            ply
            sta   CLSTMP
            ldy   #1
            phx
            txa
            clc
            adc   #1
            tay
            lda   (PTR2),y
            plx
            cmp   CLSTMP
            bne   :cskip
            inx
            cpx   CLSLEN
            bne   :cmatch
*-- the name matched; require the closing ":]"
            txa
            clc
            adc   ESCNPOS
            tay
            lda   (PTR0),y
            cmp   #$BA                  ;':'
            bne   :cskip
            iny
            lda   (PTR0),y
            cmp   #$DD                  ;']'
            bne   :cskip
            iny
            sty   ESCSRC                ;resume past "]"
            bra   :cemit
:cskip      lda   PTR2                  ;next record: 1 + name +
            clc                         ;1 + 2*nranges
            adc   CLSLEN
            adc   #1
            sta   PTR2
            lda   PTR2+1
            adc   #0
            sta   PTR2+1
            ldy   #0
            lda   (PTR2),y              ;nranges
            asl   a
            sec
            adc   PTR2
            sta   PTR2
            lda   PTR2+1
            adc   #0
            sta   PTR2+1
            bra   :crec
*-- emit every byte of every range
:cemit      lda   PTR2
            clc
            adc   CLSLEN
            adc   #1
            sta   PTR2
            lda   PTR2+1
            adc   #0
            sta   PTR2+1
            ldy   #0
            lda   (PTR2),y
            sta   CLSN
            ldx   #1
:crange     lda   CLSN
            beq   :cdone
            txa
            tay
            lda   (PTR2),y
            sta   CLSLO
            iny
            lda   (PTR2),y
            sta   CLSHI
            inx
            inx
:cbyte      ldy   ESCDST
            lda   CLSLO
            sta   ESCBUF,y
            inc   ESCDST
            beq   :cdone                ;ESCBUF full: stop
            lda   CLSLO
            cmp   CLSHI
            beq   :cnext
            inc   CLSLO
            bra   :cbyte
:cnext      dec   CLSN
            bra   :crange
:cdone      rts
*-- unknown name: the '[' is just a character
:cnone      ldy   ESCSRC
            lda   (PTR0),y
            ldy   ESCDST
            sta   ESCBUF,y
            inc   ESCDST
            inc   ESCSRC
            rts

*-- [namelen][name][nranges][lo,hi]... , 0 ends the table.
CLSTAB
            dfb   5
            asc   "alpha"
            dfb   2
            dfb   $C1,$DA,$E1,$FA
            dfb   5
            asc   "digit"
            dfb   1
            dfb   $B0,$B9
            dfb   5
            asc   "alnum"
            dfb   3
            dfb   $B0,$B9,$C1,$DA,$E1,$FA
            dfb   5
            asc   "lower"
            dfb   1
            dfb   $E1,$FA
            dfb   5
            asc   "upper"
            dfb   1
            dfb   $C1,$DA
            dfb   5
            asc   "space"
            dfb   3
            dfb   $A0,$A0,$89,$8D,$FF,$FF
            dfb   5
            asc   "blank"
            dfb   2
            dfb   $A0,$A0,$89,$89
            dfb   6
            asc   "xdigit"
            dfb   3
            dfb   $B0,$B9,$C1,$C6,$E1,$E6
            dfb   5
            asc   "print"
            dfb   1
            dfb   $A0,$FE
            dfb   5
            asc   "graph"
            dfb   1
            dfb   $A1,$FE
            dfb   5
            asc   "cntrl"
            dfb   1
            dfb   $80,$9F
            dfb   5
            asc   "punct"
            dfb   4
            dfb   $A1,$AF,$BA,$C0,$DB,$E0,$FB,$FE
            dfb   0

