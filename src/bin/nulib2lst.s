*---------------------------------------------------------------
* nulib2lst.s -- LISTING: what `-t` and `-v` put on the screen,
* and the formatters they need.
*
* `-t` is bare names, one per line, because that is what
* nulib2's own -t is: output meant for another program. `-v` is
* the decorated row, in ls -l's column discipline rather than
* ShrinkIt's wider one -- the LETTER is borrowed from nulib2,
* the layout is maux's.
*---------------------------------------------------------------

*---------------------------------------------------------------
* PRNAME -- one bare filename per line, and NOTHING else. This
* is nulib2's own `-t`: "list the filenames, one per line,
* without any truncation or embellishment. Useful for feeding
* into another program." The decorated listing is its `-v`, and
* PRROW below is that. Getting the two letters the wrong way
* round is exactly the semantic drift this project refuses --
* a `nulib2 -t` whose output cannot be piped into `while read`
* would be a different program wearing the same flag.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRNAME      lda   HAVEFN
            bne   :named
            lda   #<NONAME
            sta   PTR0
            lda   #>NONAME
            sta   PTR0+1
            bra   :puts
:named      lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
:puts       ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$0D
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* PRROW -- one listing row, in ls -l's own column discipline so
* the two look like one system:
*
*   TTT SSSSSSSS $AAAA NAME
*
* TTT is ls.s's rule exactly ($04 TXT, $06 BIN, $0F DIR, $FF
* SYS, $FC BAS, else "$xx" -- always 3 characters, so the column
* never pads). SSSSSSSS is the DATA FORK's thread_eof as
* right-aligned 8, or "-" for a record with no data thread (a
* directory, or one carrying only a resource fork). A record
* whose header CRC failed is marked with a leading '!'.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRROW       lda   CRCBAD
            beq   :notbad
            lda   #$21               ;'!'
            ldx   #FD_STDOUT
            jsr   PUTC
            bra   :type
:notbad     lda   #$20
            ldx   #FD_STDOUT
            jsr   PUTC
*-- A disk row's type column is 'Disk', not TTT -- the one
*-- column that is not a fixed 3 characters, deliberately.
:type       lda   ISDSKREC
            beq   :ftype
            lda   #<DISKTYP
            sta   PTR0
            lda   #>DISKTYP
            sta   PTR0+1
            ldx   #FD_STDOUT
            jsr   PUTS
            bra   :typed
:ftype      jsr   PRTYPE
:typed      lda   #$20
            ldx   #FD_STDOUT
            jsr   PUTC
            jsr   PRSIZE
            lda   #$20
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   #$24               ;'$'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   FAUX+1
            jsr   PRHEX8
            lda   FAUX
            jsr   PRHEX8
            lda   #$20
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   HAVEFN
            bne   :name
            lda   #<NONAME
            sta   PTR0
            lda   #>NONAME
            sta   PTR0+1
            bra   :puts
:name       lda   #<NAMEBUF
            sta   PTR0
            lda   #>NAMEBUF
            sta   PTR0+1
:puts       ldx   #FD_STDOUT
            jsr   PUTS
            lda   #$0D
            ldx   #FD_STDOUT
            jmp   PUTC

*---------------------------------------------------------------
* PRTYPE -- the 3-character type column, ls.s's rule exactly:
* $04 TXT, $06 BIN, $0F DIR, $FF SYS, $FC BAS, anything else as
* "$xx". Always three characters, so the column never pads.
*
* COUNTED, not sentinel-terminated, and that is not a style
* choice: the obvious $FF end-of-table marker is SYS's own type
* byte, so a sentinel loop prints "$FF" for the one type most
* likely to be in an archive. ls's loop counts for the same
* reason.
*
* Five rows COPIED from ls rather than shared, because its
* decoder lives inside lsprint.s bound to ls's own state and
* `put`ting that here would drag the whole module in. The
* MECHANISM is what is copied -- the rule and the widths. A
* sixth type means editing both.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRTYPE      ldx   #0
            stz   TYPEIDX
:lp         lda   TYPETAB,x
            cmp   FTYPE
            beq   :found
            inx
            inx
            inx
            inx
            inc   TYPEIDX
            lda   TYPEIDX
            cmp   #TYPEN
            bne   :lp
            lda   #$24               ;'$'
            ldx   #FD_STDOUT
            jsr   PUTC
            lda   FTYPE
            ldx   #FD_STDOUT
            jmp   PRHEX8
:found      inx                      ;X -> first mnemonic byte
            stx   TYPEIDX
            stz   TYPECNT
:prlp       ldx   TYPEIDX
            lda   TYPETAB,x
            ldx   #FD_STDOUT
            jsr   PUTC
            inc   TYPEIDX
            inc   TYPECNT
            lda   TYPECNT
            cmp   #3
            bne   :prlp
            rts

TYPETAB     dfb   $04
            asc   'TXT'
            dfb   $06
            asc   'BIN'
            dfb   $0F
            asc   'DIR'
            dfb   $FF
            asc   'SYS'
            dfb   $FC
            asc   'BAS'

*---------------------------------------------------------------
* PRSIZE -- the data fork's thread_eof in decimal, right-aligned
* in 8 columns, or "-" right-aligned if the record has no data
* thread (a directory, or one carrying only a resource fork).
*
* THIRTY-TWO BITS, not ls's twenty-four. ls measures a ProDOS
* EOF, which is a 3-byte field; a NuFX thread_eof is u32 and a
* disk-image thread legitimately exceeds 16 MB. Anything that
* does not fit 8 digits prints as ">99999999" -- 9 characters,
* which widens the column, and that is deliberate: a number too
* big for its column should look wrong rather than be silently
* truncated into a plausible smaller one.
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
PRSIZE      lda   HAVEDATA
            bne   :num
            lda   #<DASHCOL
            sta   PTR0
            lda   #>DASHCOL
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS
:num        jsr   U4DEC              ;sets SIZEBUF and SIZELEN
            lda   SIZELEN
            cmp   #9
            bcs   :wide
            lda   #8
            sec
            sbc   SIZELEN
            tax
            beq   :body
:padlp      lda   #$20
            phx
            ldx   #FD_STDOUT
            jsr   PUTC
            plx
            dex
            bne   :padlp
:body       lda   #<SIZEBUF
            sta   PTR0
            lda   #>SIZEBUF
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS
:wide       lda   #<TOOWIDE
            sta   PTR0
            lda   #>TOOWIDE
            sta   PTR0+1
            ldx   #FD_STDOUT
            jmp   PUTS

DASHCOL     asc   '       -'
            dfb   0
TOOWIDE     asc   '>99999999'
            dfb   0

*---------------------------------------------------------------
* U4DEC -- unsigned 32-bit DSIZE to a NUL-terminated decimal
* string in SIZEBUF, no leading zeros, length in SIZELEN.
*
* Repeated subtraction against a table of powers of ten, which
* is lsprint.s's U3DEC mechanism widened by one place -- copied
* as a MECHANISM because ls's version is bound to ls's own
* 3-byte value and its own buffer. Ten digits covers the whole
* 32-bit range (4294967295).
* CLOBBERS: A, X, Y.
*---------------------------------------------------------------
U4DEC       ldy   #0                 ;Y = SIZEBUF write index
            stz   U4_LZ
            ldx   #0                 ;X = power index * 4
:digitlp    stz   U4_DIG
:sublp      sec                      ;DSIZE -= POW10_4[X] ?
            lda   DSIZE
            sbc   POW10_4,x
            sta   U4_T
            lda   DSIZE+1
            sbc   POW10_4+1,x
            sta   U4_T+1
            lda   DSIZE+2
            sbc   POW10_4+2,x
            sta   U4_T+2
            lda   DSIZE+3
            sbc   POW10_4+3,x
            bcc   :donedig           ;went negative: put it back
            sta   DSIZE+3
            lda   U4_T
            sta   DSIZE
            lda   U4_T+1
            sta   DSIZE+1
            lda   U4_T+2
            sta   DSIZE+2
            inc   U4_DIG
            bra   :sublp
:donedig    lda   U4_DIG
            bne   :emit
            lda   U4_LZ              ;suppress leading zeros,
            bne   :emit              ;never the units digit
            cpx   #36
            beq   :emit
            bra   :nextpow
:emit       lda   #1
            sta   U4_LZ
            lda   U4_DIG
            clc
            adc   #$30               ;high-bit '0'
            sta   SIZEBUF,y
            iny
:nextpow    inx
            inx
            inx
            inx
            cpx   #40
            bne   :digitlp
            lda   #0
            sta   SIZEBUF,y
            sty   SIZELEN
            rts

*-- Powers of ten, 10^9 down to 10^0, little-endian u32 each.
POW10_4     dfb   $00,$CA,$9A,$3B    ;1000000000
            dfb   $00,$E1,$F5,$05    ;100000000
            dfb   $80,$96,$98,$00    ;10000000
            dfb   $40,$42,$0F,$00    ;1000000
            dfb   $A0,$86,$01,$00    ;100000
            dfb   $10,$27,$00,$00    ;10000
            dfb   $E8,$03,$00,$00    ;1000
            dfb   $64,$00,$00,$00    ;100
            dfb   $0A,$00,$00,$00    ;10
            dfb   $01,$00,$00,$00    ;1
