*---------------------------------------------------------------
* odtype.s -- od's type engine: the -t type_string parser, the
* column-width setup, and the ONE row printer every format goes
* through (hex, octal, decimal, named and C-escaped characters,
* and the legacy -b/-c/-x letters, which are just specs).
* `put` by src/bin/od.s (NOT a standalone binary -- the same
* put-module shape as odrow.s). Every symbol it touches resolves
* against od.s's own equates, zero page pointers and dum cells.
*
* THE MODEL. A format is a SPEC: a kind letter (x o u d a c,
* plus
* k for the legacy -c) and a unit size (1 2 4). A row is 16
* bytes
* and each spec prints it as 16/size units on its own line. The
* spec table is SPKIND/SPSIZE: slots 0-2 are the legacy
* letters in
* their ruled order (x, b, c), slots 3.. are -t specs in argv
* order, and OD_TSETUP squeezes the empty slots out.
*
* WHY THE FIELD WIDTHS LOOK LIKE THIS (measured, both oracles,
* docs/POSIX-ODT-NOTES.md sec 1). A field is 1 + max-digits wide
* (x1 3, x2 5, x4 9, o 4/7/12, u 4/6/11, d 5/7/12, a and c 4).
* With SEVERAL types GNU od stretches every type to the widest
* type's BLOCK (BIGSZ bytes, the largest unit size in the
* invocation) and spreads the slack over a type's k = BIGSZ/size
* fields at the ceil(W*j/k) boundaries -- so x1 beside d2 pads
* the
* 1st and 3rd of four fields. The same rule gives plain natural
* widths when only one type is present. BSD pads differently and
* leaves trailing blanks; XCU is silent; GNU's is the layout
* that
* needs no trailing blanks, which is what the existing hex row
* already was. Widths are precomputed per field position into
* WTAB (4 bytes a spec: k is never above 4).
*
* ALIGN is 0 for the legacy letters alone (each format keeps its
* own natural width and repeats the offset on every line, as the
* passing rows pin) and 1 once any -t/-d/-o/-s is given (widths
* stretched, later lines carry a BLANK offset, as both hosts
* do).
*
* Values are assembled little-endian into OD_V0..OD_V3, a unit
* shorter than 4 bytes zero-extended; the last unit of a short
* row is zero-padded by OD_PADROW (LINEBUF has 4 spare bytes).
* Digits are produced least-significant first into FLD and then
* reversed. Decimal is a 32-bit shift-and-subtract divide by ten
* (OD_DIV10), one pass of 32 shifts a digit, ten digits at most.
*---------------------------------------------------------------

*---------------------------------------------------------------
* OD_OPTX -- A = an option letter od.s did not recognise.
* carry CLEAR: handled (-t, -v, -d, -o, -s); carry SET: not ours
* or a bad type_string. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OD_OPTX     and   #$7F                  ;argv is high-bit
            cmp   #'t'
            bne   :not_t
            lda   OPTARG
            sta   PTR0
            lda   OPTARG+1
            sta   PTR0+1
            jmp   OD_TPARSE
:not_t      cmp   #'v'
            bne   :not_v
            sta   VFLAG
            clc
            rts
:not_v      ldx   #'u'                  ;-d is -t u2
            cmp   #'d'
            beq   :fix
            ldx   #'o'                  ;-o is -t o2
            cmp   #'o'
            beq   :fix
            ldx   #'d'                  ;-s is -t d2
            cmp   #'s'
            beq   :fix
            sec
            rts
:fix        stx   OD_TKIND
            lda   #2
            sta   OD_TSIZE
            lda   #1
            sta   ALIGN
            lda   OD_TKIND
            jmp   OD_TADD

*---------------------------------------------------------------
* OD_TADD -- A = kind letter (low ASCII), OD_TSIZE = unit size:
* append one spec. carry SET when the table (8 -t slots) is
* full.
*---------------------------------------------------------------
OD_TADD     ldx   NSLOT
            cpx   #11
            bcs   :full
            sta   SPKIND,x
            lda   OD_TSIZE
            sta   SPSIZE,x
            inc   NSLOT
            clc
            rts
:full       sec
            rts

*---------------------------------------------------------------
* OD_TPARSE -- PTR0 = a type_string. Grammar: one or more of
* a | c | (d|o|u|x)[size], size = 1 | 2 | 4 | C | S | I | L, no
* separators ("x1c" is x1 then c). No size on d o u x means 4
* (the
* hosts' int; a 16-bit C would say 2, the oracle says 4). L is
* 4:
* this is a 16-bit machine, there is no 8-byte unit, and x8 is a
* refusal, not a narrowed dump -- so is every other digit, and a
* second digit after a good one (x14, x16). carry SET on any
* error. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OD_TPARSE   lda   #1
            sta   ALIGN
            ldy   #0
            lda   (PTR0),y
            beq   :bad                  ;empty type_string
:next       lda   (PTR0),y
            beq   :ok
            and   #$7F
            iny
            sta   OD_TKIND
            cmp   #'a'
            beq   :one
            cmp   #'c'
            beq   :one
            cmp   #'d'
            beq   :sized
            cmp   #'o'
            beq   :sized
            cmp   #'u'
            beq   :sized
            cmp   #'x'
            bne   :bad
:sized      lda   #4
            sta   OD_TSIZE
            lda   (PTR0),y
            and   #$7F
            ldx   #6
:sz         cmp   OD_SZCHR,x
            beq   :gotsz
            dex
            bpl   :sz
            cmp   #'0'                  ;no size letter or digit
            bcc   :add
            cmp   #':'
            bcc   :bad ;a digit that is not 1 2 4
            bra   :add
:gotsz      lda   OD_SZVAL,x
            sta   OD_TSIZE
            iny
            lda   (PTR0),y
            and   #$7F
            cmp   #'0'
            bcc   :add
            cmp   #':'
            bcc   :bad                  ;two digits: x14, x16
            bra   :add
:one        lda   #1
            sta   OD_TSIZE
:add        lda   OD_TKIND
            jsr   OD_TADD
            bcs   :bad
            bra   :next
:ok         clc
            rts
:bad        sec
            rts

OD_SZCHR    dfb   $31,$32,$34,$43,$53,$49,$4C   ;1 2 4 C S I L
OD_SZVAL    dfb   1,2,4,1,2,4,4

*---------------------------------------------------------------
* OD_TSETUP -- after the options: squeeze out empty slots, then
* per spec its digit count (SPDIG), the field count per block
* (SPK), its natural block width (SPN), the stretched block
* width
* WBLK, and the per-field widths WTAB. CLOBBERS: A, X, Y.
*---------------------------------------------------------------
OD_TSETUP   ldx   #0
            ldy   #0
:sq         cpx   NSLOT
            bcs   :sqdone
            lda   SPKIND,x
            beq   :sqskip
            sta   SPKIND,y
            lda   SPSIZE,x
            sta   SPSIZE,y
            iny
:sqskip     inx
            bra   :sq
:sqdone     sty   NSPEC

            stz   BIGSZ
            ldx   #0
:big        cpx   NSPEC
            bcs   :bigdone
            lda   SPSIZE,x
            cmp   BIGSZ
            bcc   :nobig
            sta   BIGSZ
:nobig      jsr   OD_DIGITS
            sta   SPDIG,x
            inx
            bra   :big
:bigdone    stz   WBLK
            ldx   #0
:nat        cpx   NSPEC
            bcs   :natdone
            jsr   OD_KOF                ;A = k
            sta   SPK,x
            sta   OD_T1
            lda   SPDIG,x
            clc
            adc   #1 ;1 + digits = natural width
            sta   OD_T2
            lda   #0
            ldy   OD_T1
:mul        clc
            adc   OD_T2
            dey
            bne   :mul
            sta   SPN,x
            cmp   WBLK
            bcc   :nonew
            sta   WBLK
:nonew      inx
            bra   :nat
:natdone    ldx   #0
            stx   OD_WI
:wid        cpx   NSPEC
            bcc   :widgo
            rts
:widgo      lda   ALIGN
            beq   :own
            lda   WBLK
            bra   :havew
:own        lda   SPN,x
:havew      sta   OD_W
            stz   OD_ACC
            stz   OD_PB
            lda   SPK,x
            sta   OD_J
:fld        clc
            lda   OD_ACC
            adc   OD_W
            sta   OD_ACC
            clc
            adc   SPK,x
            sbc   #0                    ;carry clear: A - 1
            sta   OD_T1                 ;acc + k - 1
            lda   SPK,x
            lsr   a                     ;lg k (k is 1 2 or 4)
            tay
            lda   OD_T1
:shr        dey
            bmi   :shd
            lsr   a
            bra   :shr
:shd        sta   OD_T1                 ;boundary j
            sec
            sbc   OD_PB
            ldy   OD_WI
            sta   WTAB,y
            inc   OD_WI
            lda   OD_T1
            sta   OD_PB
            dec   OD_J
            bne   :fld
            inx                         ;next spec's row: x*4
            txa
            asl   a
            asl   a
            sta   OD_WI
            bra   :wid

*-- A = k = BIGSZ / SPSIZE,x (both powers of two: BIGSZ shifted
*-- right by lg(size) = size >> 1). Preserves X.
OD_KOF      lda   SPSIZE,x
            lsr   a
            tay
            lda   BIGSZ
:sh         dey
            bmi   :done
            lsr   a
            bra   :sh
:done       rts

*-- A = digits of spec X's field (X preserved): row = kind in
*-- OD_KINDS, column = size >> 1. a/c/k rows repeat one value.
OD_DIGITS   lda   SPKIND,x
            ldy   #6
:k          cmp   OD_KINDS,y
            beq   :got
            dey
            bpl   :k
:got        tya
            sta   OD_T1
            asl   a
            adc   OD_T1                 ;3 * row (carry clear)
            sta   OD_T1
            lda   SPSIZE,x
            lsr   a
            clc
            adc   OD_T1
            tay
            lda   OD_DIGTAB,y
            rts

OD_KINDS    dfb   $78,$6F,$75,$64,$61,$63,$6B ;x o u d a c k
OD_DIGTAB   dfb   2,4,8                              ;x1 x2 x4
            dfb   3,6,11                             ;o
            dfb   3,5,10                             ;u
            dfb   4,6,11 ;d (sign room)
            dfb   3,3,3                              ;a
            dfb   3,3,3                              ;c
            dfb   1,1,1 ;k (legacy -c)

*---------------------------------------------------------------
* OD_EMIT -- one filled row (LINECNT bytes in LINEBUF). A full
* row
* identical to the previous full row prints as a single "*" line
* for the whole run (POSIX; -v prints them all); everything else
* prints through PRSPECS. A short row is never suppressed.
*---------------------------------------------------------------
OD_EMIT     lda   LINECNT
            cmp   #ROWMAX
            bne   :print
            lda   VFLAG
            bne   :print
            lda   HAVEPREV
            beq   :print
            ldx   #ROWMAX-1
:cmp        lda   LINEBUF,x
            cmp   PREVBUF,x
            bne   :print
            dex
            bpl   :cmp
            lda   SUPP
            bne   :done
            lda   #1
            sta   SUPP
            lda   #'*'                  ;high-bit for PUTC
            ora   #$80
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$8D
            ldx   #FD_STDOUT
            jmp   PUTC
:done       rts
:print      stz   SUPP
            lda   LINECNT
            cmp   #ROWMAX
            bne   :nosave
            ldx   #ROWMAX-1
:save       lda   LINEBUF,x
            sta   PREVBUF,x
            dex
            bpl   :save
            lda   #1
            sta   HAVEPREV
:nosave     jmp   PRSPECS

*---------------------------------------------------------------
* PRSPECS -- print the row in LINEBUF once per spec.
*---------------------------------------------------------------
PRSPECS     ldx   LINECNT ;zero the spare bytes so a
            stz   LINEBUF,x             ;partial last unit pads
            stz   LINEBUF+1,x           ;with zeros
            stz   LINEBUF+2,x
            stz   LINEBUF+3,x
            stz   CURSPEC
:spec       ldx   CURSPEC
            cpx   NSPEC
            bcc   :go
            rts
:go         txa
            beq   :off
            lda   ALIGN
            beq   :off
            jsr   OD_BLANKOFF
            bra   :units
:off        jsr   PRHEX4
:units      ldx   CURSPEC
            lda   SPSIZE,x
            clc
            adc   LINECNT
            sbc   #0                    ;carry clear: size+n-1
            sta   OD_T1
            lda   SPSIZE,x
            lsr   a
            tay
            lda   OD_T1
:sh         dey
            bmi   :shd
            lsr   a
            bra   :sh
:shd        sta   NUNITS
            stz   CURUNIT
:unit       lda   CURUNIT
            cmp   NUNITS
            bcs   :cr
            jsr   OD_LOADV
            jsr   OD_FIELD
            ldx   CURSPEC
            sec
            lda   SPK,x
            sbc   #1
            and   CURUNIT               ;field position in block
            sta   OD_T1
            txa
            asl   a
            asl   a
            clc
            adc   OD_T1
            tay
            lda   WTAB,y
            sec
            sbc   FLEN
            jsr   OD_SPACES
            jsr   OD_PUTFLD
            inc   CURUNIT
            bra   :unit
:cr         lda   #$8D
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   CURSPEC
            bra   :spec

*-- the offset column's width in spaces, per -A base.
OD_BLANKOFF ldx   #4
            lda   OD_ABASE
            and   #$7F
            cmp   #'n'
            beq   :none
            cmp   #'d'
            bne   :nd
            ldx   #5
:nd         cmp   #'o'
            bne   :no
            ldx   #6
:no         txa
            bra   OD_SPACES
:none       rts

*-- A spaces (0 prints none).
OD_SPACES   sta   OD_CNT
            beq   :done
:lp         lda   #$A0
            ldx   #FD_STDOUT
            jsr   PUTC
            dec   OD_CNT
            bne   :lp
:done       rts

OD_PUTFLD   stz   OD_IDX
:lp         ldx   OD_IDX
            cpx   FLEN
            bcs   :done
            lda   FLD,x
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   OD_IDX
            bra   :lp
:done       rts

*---------------------------------------------------------------
* OD_LOADV -- OD_V0..3 = unit CURUNIT of spec CURSPEC, little
* endian, zero-extended. FSIZE = its size.
*---------------------------------------------------------------
OD_LOADV    ldx   CURSPEC
            lda   SPSIZE,x
            sta   FSIZE
            lsr   a
            tay
            lda   CURUNIT
:sh         dey
            bmi   :shd
            asl   a
            bra   :sh
:shd        tay                         ;byte offset, at most 19
            stz   OD_V0
            stz   OD_V0+1
            stz   OD_V0+2
            stz   OD_V0+3
            ldx   #0
:cp         lda   LINEBUF,y
            sta   OD_V0,x
            iny
            inx
            cpx   FSIZE
            bcc   :cp
            rts

*---------------------------------------------------------------
* OD_FIELD -- FLD/FLEN = the text of the unit in OD_V0..3 for
* spec
* CURSPEC (high-bit ASCII, ready for PUTC).
*---------------------------------------------------------------
OD_FIELD    stz   FLEN
            ldx   CURSPEC
            lda   SPKIND,x
            cmp   #'x'
            beq   OD_FHEX
            cmp   #'o'
            beq   OD_FOCT
            cmp   #'u'
            beq   OD_FUNS
            cmp   #'d'
            beq   OD_FSGN
            cmp   #'a'
            bne   :not_a
            jmp   OD_FNAME
:not_a      cmp   #'c'
            bne   :not_c
            jmp   OD_FCHAR
:not_c
*-- 'k': the legacy -c -- strip, printable as itself, else "."
            lda   OD_V0
            and   #$7F
            cmp   #$20
            bcc   :dot
            cmp   #$7F
            bcs   :dot
            ora   #$80
            jmp   OD_FPUT
:dot        lda   #$AE
            jmp   OD_FPUT

OD_FPUT     ldx   FLEN
            sta   FLD,x
            inc   FLEN
            rts

*-- hex and octal: SPDIG digits, 4 or 3 bits each.
OD_FHEX     lda   #4
            ldx   #$0F
            bra   OD_FRADIX
OD_FOCT     lda   #3
            ldx   #7
OD_FRADIX   sta   OD_BITS
            stx   OD_MASK
            ldx   CURSPEC
            lda   SPDIG,x
            sta   OD_CNT
:dl         lda   OD_V0
            and   OD_MASK
            cmp   #10
            bcc   :dig
            adc   #$B6                  ;carry set: +$B7 -> A..F
            bra   :put
:dig        ora   #$B0
:put        jsr   OD_FPUT
            ldx   OD_BITS
:shr        lsr   OD_V0+3
            ror   OD_V0+2
            ror   OD_V0+1
            ror   OD_V0
            dex
            bne   :shr
            dec   OD_CNT
            bne   :dl
            jmp   OD_FREV

*-- decimal. d: sign-extend a short unit, negate a negative one,
*-- and remember to put the '-' on the end (it is reversed in).
OD_FUNS     stz   OD_NEG
            bra   OD_FDEC
OD_FSGN     stz   OD_NEG
            ldx   FSIZE
            lda   OD_V0-1,x
            bpl   OD_FDEC
            lda   #0
            eor   #$FF
:ext        cpx   #4
            bcs   :neg
            sta   OD_V0,x
            inx
            bra   :ext
:neg        inc   OD_NEG
            sec
            ldx   #0
            ldy   #4
:n          lda   #0
            sbc   OD_V0,x
            sta   OD_V0,x
            inx
            dey
            bne   :n
OD_FDEC     jsr   OD_DIV10
            ora   #$B0
            jsr   OD_FPUT
            lda   OD_V0
            ora   OD_V0+1
            ora   OD_V0+2
            ora   OD_V0+3
            bne   OD_FDEC
            lda   OD_NEG
            beq   OD_FREV
            lda   #$AD                  ;'-'
            jsr   OD_FPUT
*-- reverse FLD[0..FLEN-1] in place
OD_FREV     ldx   #0
            ldy   FLEN
            dey
:lp         stx   OD_T2
            cpy   OD_T2
            bcc   :done
            beq   :done
            lda   FLD,x
            pha
            lda   FLD,y
            sta   FLD,x
            pla
            sta   FLD,y
            inx
            dey
            bra   :lp
:done       rts

*-- OD_V0..3 = OD_V0..3 / 10, A = remainder. 32 shift-subtracts;
*-- bit 0 of the quotient is free after each shift, so INC
*sets it.
OD_DIV10    ldx   #32
            lda   #0
:lp         asl   OD_V0
            rol   OD_V0+1
            rol   OD_V0+2
            rol   OD_V0+3
            rol   a
            cmp   #10
            bcc   :nx
            sbc   #10
            inc   OD_V0
:nx         dex
            bne   :lp
            rts

*-- a: the XCU named characters. Only the low seven bits count
*-- (XCU says so; GNU masks, BSD does not -- the row is pinned
*-- from the text). 0-32 are names, 127 is del, the rest print.
OD_FNAME    lda   OD_V0
            and   #$7F
            cmp   #33
            bcc   :named
            cmp   #$7F
            bne   :pr
            lda   #33                   ;del is entry 33
            bra   :named
:pr         ora   #$80
            jmp   OD_FPUT
:named      sta   OD_T1
            asl   a
            adc   OD_T1                 ;3 * index
            tax
            ldy   #0
:cp         lda   OD_ANAMES,x
            ora   #$80
            sta   FLD,y
            inx
            iny
            cpy   #3
            bne   :cp
            lda   #3
            sta   FLEN
            rts

*-- c: C escapes for NUL and 7-13, a printable byte as itself,
*-- anything else three octal digits of the RAW byte. A byte
*whose
*-- low seven bits are printable or an escape prints as that --
*-- maux text is high-bit (od.s header's HIGH-BIT RULING), and
*the
*-- check against the host feeds it the stripped byte to match.
OD_FCHAR    lda   OD_V0
            and   #$7F
            cmp   #14
            bcs   :nesc
            tax
            lda   OD_ESCTAB,x
            beq   :nesc
            pha
            lda   #$DC                  ;backslash
            jsr   OD_FPUT
            pla
            ora   #$80
            jmp   OD_FPUT
:nesc       lda   OD_V0
            and   #$7F
            cmp   #$20
            bcc   :oct
            cmp   #$7F
            bcs   :oct
            ora   #$80
            jmp   OD_FPUT
:oct        jmp   OD_FOCT ;3 digits (SPDIG of c), raw

OD_ESCTAB   dfb   $30,0,0,0,0,0,0,$61,$62,$74,$6E,$76,$66,$72
*                 \0              \a  \b  \t  \n  \v  \f  \r

OD_ANAMES   asc   'nul'
            asc   'soh'
            asc   'stx'
            asc   'etx'
            asc   'eot'
            asc   'enq'
            asc   'ack'
            asc   'bel'
            asc   ' bs'
            asc   ' ht'
            asc   ' nl'
            asc   ' vt'
            asc   ' ff'
            asc   ' cr'
            asc   ' so'
            asc   ' si'
            asc   'dle'
            asc   'dc1'
            asc   'dc2'
            asc   'dc3'
            asc   'dc4'
            asc   'nak'
            asc   'syn'
            asc   'etb'
            asc   'can'
            asc   ' em'
            asc   'sub'
            asc   'esc'
            asc   ' fs'
            asc   ' gs'
            asc   ' rs'
            asc   ' us'
            asc   ' sp'
            asc   'del'
